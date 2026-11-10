# provider=csv-file 适配器规格（按 `references/adapter-spec.md` 11 节填满）

> 数据源 = 本地 CSV 文件。零网络、零凭据、零依赖。
> 描述文件：`adapters/csv-file.adapter.json`；模块：`scripts/csv-file-adapter.ps1`；
> 自测：`tests/verify-csv-file-adapter.ps1`；样本：`scripts/sample-tasks.csv`。
> 换源边界：`patrol-loop.ps1`、`patrol-provider.ps1` 的装配契约、`schemas/item.schema.json` 均不改。

---

## 0. 先决判断

- [x] 需求是**周期性**的：CSV 由人/脚本持续维护，巡检按每行 interval 反复读。
- [x] 「要做什么」能落成**行**：CSV 一行 = 一条任务方向。
- [x] 每行对应**有界**的工作：一行一段有界 agent 工作。
- [x] 行列里能读出 id、标题、优先级、间隔；状态/动作/备注可空。

四项都满足，才该用本 provider。

## 0.1 这类源什么时候该用 / 不该用

**该用**

- 源本来就是表格导出物（Excel/GS/DB 导出的 `.csv`），且**不需要在线协作**——有人手工编辑、有脚本追加行都行，但编辑发生在文件系统上。
- 需要**离线/内网/无凭据**跑通整条链路：CI、教学、客户现场隔离环境、临时演练。
- 想给巡检做**版本化快照**：CSV 进 git，任务清单的历史可 diff、可回滚（API/在线表格做不到）。
- 只读采集 + 少量回写（回写「状态/动作/备注」三列），不需要并发写与权限模型。

**不该用**

- 多人**同时**在线编辑同一份清单：CSV 没有锁与冲突解决，后写覆盖先写；此时用 bitable / 腾讯文档。
- 需要**逐行权限、字段级审计、@提醒**等协同能力：CSV 全无，别硬套。
- 行数很大（万级以上）且高频轮询：每轮全量 `Import-Csv` 是 O(行数) 读盘，用数据库/API 增量游标更合适。
- 源是**唯一事实源且不允许落盘副本**（合规要求数据不出系统）：CSV 天然是副本，此时应走 API provider。
- 行的「事实」由别的系统实时改写，本地 CSV 只是滞后镜像：先解决镜像同步，再谈巡检，否则巡检结论建立在陈旧数据上。
- 需要**写入即触发**下游（webhook/事件）：CSV 无事件，只能轮询。

**和 local-json 怎么选**

| | `local-json` | `csv-file` |
|---|---|---|
| 主要用途 | 教学/最小样例 | 真实表格导出物接入 |
| 编辑体验 | 要懂 JSON 语法 | Excel 直接改，人可维护 |
| 写回粒度 | 整文件重写（`ConvertTo-Json`） | 只重渲命中行，其余字节不动 |
| diff 友好度 | 整文件易变 | 行级 diff 干净 |
| 多行单元格 | 天然支持 | 需引号包裹（RFC4180） |

---

## 1. 源与触发映射（Source → Trigger）

| 项 | 填 |
|---|---|
| 数据源是什么 | 本地 UTF-8 CSV 文件（一行一条任务方向），由人用 Excel/编辑器维护，或由上游脚本导出 |
| 一次「读」的范围 | 整个文件（表头 + 全部数据行）。无分页、无游标；空行与纯空白行跳过 |
| 触发方式 | Windows 计划任务 `-Once` + IgnoreNew（首选）；或 nssm 常驻；CI 里直接 `pwsh -File` |
| 触发间隔 | 每 30 分钟一轮；轮内再按每行 `interval` 过滤（`interval=0` 回退 60 分钟，与骨架一致） |
| 单实例保证 | 全局 mutex `Global\patrol-scaffold-demo`（第 2 层，与 provider 无关）+ 轮次硬超时 |

**规则**：触发层不认识厂商；换源不动触发。

---

## 2. 配置 schema（字段 / 类型 / 默认 / 健康度）

| 键 | 类型 | 默认 | 健康度判据 |
|---|---|---|---|
| `csvPath` | string（绝对路径或仓内相对路径） | `scripts/sample-tasks.csv` | 非空且文件存在；相对路径按仓根解析，取不到再按当前目录 |
| `columnMap` | string | `id=id;title=title;priority=priority;interval=interval;status=status;action=action;note=note` | 每个键值对是 `key=列名`；键只能是 id/title/priority/interval/status/action/note |
| `tasksFile` | string（**装配层注入**，非本 provider 配置） | 空 | 只有以 `.csv` 结尾时才采纳；否则打警告并回退 `csvPath` |
| 环境变量覆盖 | `PATROL_CSV_FILE_CSVPATH` / `PATROL_CSV_FILE_COLUMNMAP` | — | 装配层约定：`PATROL_<PROVIDER>_<KEY>` 覆盖同名 config |

**规则**

- 无凭据、无 token：本 provider 不读任何密钥，`needsCredentials=false`、`needsNetwork=false`。
- `columnMap` 只写要改的键，其余按同名列回退；写了不存在的键 → 启动即报错点名该键。
- 健康度判据可直接被看门狗用：**文件存在 + Import-Csv 能解析 + 必填列齐 + id 唯一**，任一不满足即「坏」，由 `Get-PatrolItems` 抛错暴露。
- **`tasksFile` 的语义边界**：装配层对所有 provider 都注入 `tasksFile`（`patrol-loop.ps1 -TasksFile`），CSV 只在它是 `.csv` 时采纳。这样 `-TasksFile tasks.csv` 直接可用，而契约自测默认塞进来的 `sample-tasks.json` 不会被误当 CSV 解析（会打一条警告，不静默）。

---

## 3. 触发器构造

- [x] 计划任务名：`CodexPatrol-csv-file`（按 `CodexPatrol-<name>` 约定；本 provider 无专属触发器代码）
- [x] 轮次硬超时：`RoundTimeoutSec = 1500`（超时让位下一次触发，不堆叠）
- [x] 并发上限：`MaxPatrolChildren = 3`（并发上限，非每轮取 N 条）
- [x] 失败重置：连续 3 次失败后不复用旧线程（第 3 层，与 provider 无关）

CSV 场景的两条补充：

- **文件被 Excel 占用/写了一半**：读端会得到 `Import-Csv` 的解析错误或必填列缺失错误——按「本轮失败、下轮重试」处理，不要重试到死循环（沿用连续失败重置）。
- **谁来写这个文件**：只允许「一条生产线」写（人或一个导出脚本）。多个写入者请改用在线表格 provider。

---

## 4. 接收范围（scope）

| 项 | 填 |
|---|---|
| 哪些行进入巡检 | 表头之后的全部非空数据行（空行、纯空白行自动跳过） |
| 哪些行明确排除 | 无内置排除。要排除就**在导出侧过滤**，或按 `status` 值在 worker 侧判定；本适配器不静默丢行 |
| 每次最多取多少 | 全量。行数建议 ≤ 2000；更多请改增量或换源 |
| 假数据/演练开关 | 无专属列；用 `patrol-loop.ps1 -DryRun` 全局演练（worker 不真跑） |

**规则**：不静默丢行——排除逻辑必须显式（要么导出侧过滤，要么行内状态可判），避免「以为巡了 100 行其实只巡了 80 行」。

---

## 5. 回复通道（Channel）

| 项 | 填 |
|---|---|
| 结果写回哪 | 同一个 CSV 的 `status` / `action` / `note` 三列（可由 `columnMap` 改名） |
| 写回开关 | 默认**不写**：`patrol-loop.ps1` 把运行态外置到 `state/patrol-state.json`，不调用 write-back；要回写源必须显式调 `Save-PatrolItems` / `Set-PatrolCsvRowFields` |
| 写回粒度 | 行级：只重渲命中记录的原始行文本，其余行的字节（含引号风格、各自的行尾 CRLF/LF）原样拼回；行序不变；落盘 `Set-Content -Encoding utf8NoBOM` |
| 人工通知 | 与源解耦：摘要走 digest（JSON+MD）/ Obsidian 记忆；要推送再加机器人，不动本适配器 |
| 空值语义 | 只写「非空」的 item 字段：`currentStage→status`、`nextStep→action`、`achievement→note`；空字段不会把源单元格清空 |

**规则**：源默认只读。写回是「显式调用」的行为，不是轮询的副作用。

---

## 6. 线程上下文（Thread）

- [ ] 行内 `threadId` 列：**本 provider 不落盘 threadId**。CSV 的七列里没有该列，运行态（threadId、lastRun）统一留在 `state/patrol-state.json`（第 4 层 sync-back 的运行态外置）。
- [x] 若确实需要「人能在表里看到线程 id」：在 CSV 加一列 `threadId`，并把 `columnMap` 的 `note` 指向它并不会自动生效——需要扩展适配器映射（属契约外扩展，先在 spec 里登记再改）。
- [x] 连续失败 3 次后重置为新建（第 3 层职责，与 provider 无关）。

---

## 7. 策略（Policy）

- [x] 源默认**只读**；写回必须显式调 `Save-PatrolItems` / `Set-PatrolCsvRowFields`。
- [x] worker 只做有界、可逆的本地改动；不发布、不动外部系统。
- [x] 关联器只读 `git status/log`，不 commit/push。
- [x] 本适配器不联网、不引依赖、不读环境里的任何密钥；`Import-Csv` + `Set-Content` 之外没有 IO。
- [x] 写回前做**结构自检**：`Import-Csv` 的记录数必须与原文记录段数一致，否则拒绝写回（宁可不写，不破坏格式）。

---

## 8. 执行变量

| 变量 | 来源 | 用途 |
|---|---|---|
| `id` | `columnMap.id` 列（必填，唯一） | 续跑/回写定位；空或重复 → 报错 |
| `title` | `columnMap.title` 列（必填） | 拼 worker prompt；空则回退 `id` |
| `priority` | `columnMap.priority` 列（必填） | 排序（P0 先）；大小写由 `ConvertTo-PatrolItem` 归一，非法值退 `P2` |
| `interval` | `columnMap.interval` 列（必填） | 到期判定；空 → 0，非整数 → 报错点名行号与值 |
| `status` | `columnMap.status` 列（可空） | → `currentStage`（摘要与回写都用） |
| `action` | `columnMap.action` 列（可空） | → `nextStep`（回写用） |
| `note` | `columnMap.note` 列（可空） | → `description`（拼 prompt / 回写 achievement） |
| `repoPath` / `threadId` / `fake` / `lastRun` | 无对应列 | 由 provider 层填默认值（空串 / null / false / null），运行态走 state 文件 |

**规则**：prompt 里仍要带「时间自控：超时主动拆分到下一轮」（第 3 层，改 prompt 不改 provider）。

---

## 9. 插件入口与循环（适配器模块）

模块只提供契约三函数，外加两个便利封装：

```powershell
function Get-PatrolItems      { param([string]$CsvPath, [string]$TasksFile, [string]$ColumnMap) }  # list-items()
function Save-PatrolItems     { param([string]$CsvPath, [string]$TasksFile, $Items, [string]$ColumnMap) }  # write-back()
function Resolve-ItemName     { param($Item) }                                                     # resolve-name()
function Set-PatrolCsvRowFields { param([string]$CsvPath, [string]$TasksFile, [string]$Id, [hashtable]$Fields, [string]$ColumnMap) }  # 单行单列外科手术
```

实现要点（与 local-json 同一把尺子）：

- **解析只用 `Import-Csv -Encoding utf8`**：引号内逗号、引号内换行、双写引号、CRLF/LF 混排、空行/纯空白行都交给它；不手写 `split`。
- **记录边界单独定位**：写回要在不整表重排的前提下改一行，所以另有一个只找记录起止偏移的扫描器（RFC4180 引号规则）。它**不切字段**——字段值一律来自 `Import-Csv`，扫描器只回答「这条记录在原文字节的哪一段」。
- **必填列缺失即报错**：错误文本点名缺哪列、文件现有列有哪些、用 `columnMap` 怎么改，绝不静默当空。
- **写回只动命中行**：`Set-Content -NoNewline -Encoding utf8NoBOM`，无 BOM；同值写回返回 0 且不改文件（幂等）。
- 形状不一的 item 由 provider 层 `ConvertTo-PatrolItem` 归一，适配器不造轮子。

---

## 10. 插件注册（描述文件）

```json
{
  "provider": "csv-file",
  "title": "本地 CSV 文件",
  "module": "scripts/csv-file-adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "config": { "csvPath": "scripts/sample-tasks.csv", "columnMap": "id=id;title=title;..." },
  "listItems":   { "function": "Get-PatrolItems",  "args": { "CsvPath": "${csvPath}", "TasksFile": "${tasksFile}", "ColumnMap": "${columnMap}" } },
  "writeBack":   { "function": "Save-PatrolItems", "args": { "CsvPath": "${csvPath}", "TasksFile": "${tasksFile}", "ColumnMap": "${columnMap}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
```

- 无本机绝对路径、无 token、无运行时产物路径写死。
- `${token}` 由装配层注入；`PATROL_CSV_FILE_CSVPATH` 等环境变量优先于 descriptor 默认值。
- **装配层注意（已修）**：三个契约函数名在各 provider 间是同名的，`Import-PatrolProvider` 必须无条件提升描述文件声明的函数名到脚本作用域；只提升「新增函数名」会让第二个 provider 的调用落到上一个 provider 的函数上（表现为「找不到与参数名称 X 匹配的参数」）。

---

## 11. 测试清单

**必做（自动化）**

- [x] `pwsh -NoProfile -File scripts/adapter-contract-test.ps1` → `pass=2 skip=2 fail=0`（bitable / tencent-docs 无凭据为 SKIP 而非 FAIL）
- [x] `pwsh -NoProfile -File tests/verify-csv-file-adapter.ps1` → `pass=43 fail=0`（行数/映射、引号逗号与换行、中文表头 columnMap、缺列非零退出、写回字节保真/无 BOM/幂等/异常）
- [x] `pwsh -NoProfile -File tests/verify-no-secrets.ps1` → PASS（本 provider 不读任何密钥）
- [x] `PATROL_ADAPTER=csv-file; pwsh -File scripts/patrol-loop.ps1 -TasksFile <csv> -StateFile <temp> -Once -DryRun` → `due=3/3`，三个 worker 完成，digest `method=csv-file`
- [x] 立刻重跑 → `due=0/3`（per-row interval + state 合并生效）

**必做（人工）**

- [x] 无凭据时不需要 SKIP 逻辑：本 provider 永远可实跑（`needsCredentials=false`）
- [x] 只读模式下游系统零写入：不调 `Save-PatrolItems` 就一个字节都不写
- [ ] 写回开关：当前是「显式调用即写」，没有 descriptor 级 `syncBack` 双门；需要在自动化里无人值守回写时，先补这个门

**不该有的**

- [x] 描述文件里没有本机绝对路径
- [x] 仓里没有 token / key / 口令
- [x] 仓里没有运行时产物（`downloads/` `reports/` `state/` 均在 .gitignore）

---

## 完成标准

新增本 provider = **两个文件**（`adapters/csv-file.adapter.json` + `scripts/csv-file-adapter.ps1`）+ 一次契约自测 PASS，外加离线自测与样本 CSV。`patrol-loop.ps1` 一行未改。

## 已知边界

1. **并发写**：两个进程同时对同一 CSV 写回，后写覆盖先写。生产上只允许一条写生产线，或改在线表格 provider。
2. **单文件全量读**：每轮全量解析，行数大时是纯 IO 成本；万级行请换源。
3. **编码**：只处理 UTF-8（有无 BOM 都能读，写回一律无 BOM）。GBK/UTF-16 的 CSV 需先转码，否则中文会成乱码而不是报错。
4. **Excel 独占打开**：Windows 上 Excel 打开时文件可能被锁，写回会抛共享冲突——按本轮失败处理。
5. **`threadId` 无落盘列**：续跑上下文只在 `state/patrol-state.json`；换机/清 state 会丢续跑线索。
