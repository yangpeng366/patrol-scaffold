# 加一个数据源要动多少东西（以 `command` 适配器为完整样例）

> 这份文档回答一个问题：**这套骨架的适应性到底强在哪、账怎么算**。
> 拿「命令型源」从零走了一遍，所有数字都来自本次实际改动（`git diff --numstat`），不是估计。
> 逐键逐函数的操作手册在 `references/adding-a-provider.md`；业务判断填表在 `references/adapter-spec.md`。
> 本文只讲三件事：改了什么、坑在哪、什么时候必须动核心。

---

## 0. 本次实测的账

| 项 | 数值 |
|---|---|
| **核心改动**（`scripts/patrol-provider.ps1` / `scripts/patrol-loop.ps1` / `scripts/adapter-contract-test.ps1` / `schemas/item.schema.json`） | **0 行**（`git diff --numstat` 对这四件为空） |
| 新增 adapter 文件 | 2 个：`adapters/command.adapter.json`（31 行）+ `scripts/command-adapter.ps1`（417 行） |
| 新增 mock 命令 fixture | 2 个：`tests/fixtures/command/mock-jobs.ps1`（55 行）+ `mock-scnet-jobs.ps1`（46 行） |
| 新增本 provider 自测 | 1 个：`tests/verify-command-adapter.ps1`（292 行 / 45 条断言） |
| 修改的既有测试 | 1 个：`tests/verify-provider-isolation.ps1`（+19 / −3，把 command 纳入「同名函数不串味」回归） |
| 流程步骤 | **8 步**（§2，含跑门禁与端到端 dry-run） |
| 端到端结果 | `due=3/3`、3 个 worker 完成、`digest.method=command`、源与核心文件零改动 |

一句话结论：**换数据源的成本 = 一个描述文件 + 一个模块（3 个函数），核心 0 行**。
适应性不在「能接多少家」，而在「接新源时没有人需要重新理解调度器」。core 的边界是硬的：
`patrol-provider.ps1` 只认 3 个槽位与「`args` 键 = 函数参数名」，`patrol-loop.ps1` 只认 item 字段。

---

## 1. 边界：哪些是核心、哪些只是 adapter

| 文件 | 角色 | 认识厂商吗 | 改它意味着什么 |
|---|---|---|---|
| `scripts/patrol-provider.ps1` | 装配 + 归一（`ConvertTo-PatrolItem`） | 不 | 改 = 改**所有** provider 的契约，等于改骨架 |
| `scripts/patrol-loop.ps1` | 调度 / worker 池 / 回写 state / digest | 不 | 改 = 调度器开始认识某个源，可移植性立刻破 |
| `schemas/item.schema.json` | item 契约唯一事实源 | 不 | 改 = 跨仓（dsh-patrol）契约漂移，`verify-item-contract-parity` 会红 |
| `scripts/adapter-contract-test.ps1` | 每个 provider 过同一把尺子 | 不 | 改 = 尺子变松/变严，所有 provider 一起受影响 |
| `tests/verify-adapter-spec.ps1` | 描述文件规则（11 键 / `E-ARGNAME` / `${...}`） | 不 | 改 = 描述文件语法变更 |
| `tests/verify-item-contract-parity.ps1` | 与 dsh-patrol 的 schema 同源校验 | 不 | 与 provider 数量无关 |
| `adapters/<name>.adapter.json` | 声明式注册（provider 名 = 文件名） | **是** | 换源就换它 |
| `scripts/<name>-adapter.ps1` | 三个契约函数的实现 | **是** | 换源就换它 |
| `tests/fixtures/<name>/` | 离线 mock（无网络无凭据） | **是** | 让 CI 能真跑这个源 |
| `tests/verify-<name>-adapter.ps1` | 本 provider 自测 | **是** | 只影响这一家 |

**登记只有一处**：`adapters/` 目录。没有任何第二份 provider 列表需要同步（`adapter-contract-test` 与
`verify-adapter-spec` 都是扫目录）。需要顺手改的只有人读清单（README / SKILL 的「文件」节）与 CI 里那一步自测。

---

## 2. 最小清单：8 步，附命令

在仓库根执行（pwsh 7）：

```powershell
# 1) 先手工确认「一次命令能吐 JSON」——这一步失败，后面全是白工
pwsh -NoProfile -Command "pwsh -NoProfile -File tests/fixtures/command/mock-jobs.ps1"

# 2) 落 mock 命令 fixture（无网络、无凭据、确定性输出；CI 要真跑）
#    tests/fixtures/command/mock-jobs.ps1

# 3) 落 adapter 模块：三个函数 Get-PatrolItems / Save-PatrolItems / Resolve-ItemName
#    scripts/command-adapter.ps1   （首行 #requires -Version 7，UTF-8 无 BOM）

# 4) 落描述文件：11 键 + optional，provider 名 = 文件名
#    adapters/command.adapter.json

# 5) 描述文件静态闸门（args 键名 / ${...} / module 存在 / 函数存在）
pwsh -NoProfile -File tests/verify-adapter-spec.ps1

# 6) 契约自测（装配 -> list-items 实跑 -> 每行过 schema -> resolve-name）
pwsh -NoProfile -File scripts/adapter-contract-test.ps1 -Provider command
pwsh -NoProfile -File scripts/adapter-contract-test.ps1          # 全量：不能把别人跑红

# 7) 本 provider 自测（负面用例都在这里，别只测 happy path）
pwsh -NoProfile -File tests/verify-command-adapter.ps1

# 8) 端到端 dry-run：digest.method 必须等于 provider 名
$env:PATROL_ADAPTER = 'command'
pwsh -NoProfile -File scripts/patrol-loop.ps1 -TasksFile scripts/sample-tasks.json `
  -StateFile (Join-Path $env:TEMP 'cmd-state.json') -Once -DryRun
```

期望输出（本次实测）：

```
[PASS] adapters/command.adapter.json  provider=command funcs=3
summary pass=5 fail=0 skip=0 warnings=0
[PASS] command  items=3  module=scripts/command-adapter.ps1
summary pass=45 fail=0                     # 本 provider 自测
[round] due=3/3 maxChildren=2 dryRun=True  # 端到端
digest.method = command
```

---

## 3. 完整样例：`command` provider

### 3.1 描述文件（`adapters/command.adapter.json`）

```json
{
  "provider": "command",
  "title": "命令型数据源（CLI 输出 JSON）",
  "module": "scripts/command-adapter.ps1",
  "kind": "cli",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "数据源是「一次命令调用输出的 JSON 数组」…",
  "config": {
    "command": "pwsh -NoProfile -File tests/fixtures/command/mock-jobs.ps1",
    "fieldMap": "id=jobId;title=jobName;priority=priority;interval=intervalMin;status=state;action=nextStep;note=note;repo=repo",
    "itemsPath": ".",
    "timeoutSec": "30",
    "mirrorFile": "state/command-mirror.json"
  },
  "listItems": {
    "function": "Get-PatrolItems",
    "args": { "Command": "${command}", "FieldMap": "${fieldMap}", "ItemsPath": "${itemsPath}", "TimeoutSec": "${timeoutSec}" }
  },
  "writeBack": { "function": "Save-PatrolItems", "args": { "MirrorFile": "${mirrorFile}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
```

逐条解释（都是被闸门逼出来的写法）：

- `provider` 必须等于文件名 `command`（`E-FILENAME`），也是 `PATROL_ADAPTER` 的取值。
- `args` 的键**逐字**等于模块里 `param(...)` 的参数名（`E-ARGNAME`，大小写敏感）：`Command` 不是 `command`。
- `args` 里不写 `-Items` / `-Item`：装配层写死注入（`& $fn @args -Items $Items`）。
- `args` 的键由 `${config 键}` 提供；`${tasksFile}` 是唯一例外（装配层对所有 provider 统一注入）。
  **每个 args 展开后都不能为空串**，否则 `Get-PatrolProviderItems` 抛「必填参数为空」——所以
  `itemsPath` 用 `.` 表示「自动识别」，而不是留空。
- `writeBack` 只给 `MirrorFile`：命令型源没有可写的行，回写只落本地镜像（见 §4「写回」）。
- `needsCredentials=false` 是给 `adapter-contract-test` 看的：它只在「`needsCredentials=true` 且
  `configPath` 为空」时 SKIP；我们不想被 SKIP，因为 mock 命令真的能跑。

### 3.2 模块要点：三个契约函数 + 5 个真实坑

```powershell
Get-PatrolItems([string]$Command, [string]$FieldMap, [string]$ItemsPath, [string]$TimeoutSec)
Save-PatrolItems([string]$MirrorFile, [Parameter(Mandatory)]$Items)   # -Items 由装配层注入
Resolve-ItemName($Item)                                              # -Item 由装配层注入
```

1. **子进程执行**：`pwsh -NoProfile -NonInteractive -Command "<命令>"`，工作目录 = 仓库根
   （由 `$PSScriptRoot` 推出来，不写死本机路径）。独立进程边界 = 真的在调一个 CLI，也不污染当前会话的函数表。
2. **退出码**：`pwsh -Command` 只回 0/1，真实 CLI 的 `2`（鉴权）/`7`（找不到目标）会被压成 1。
   模块把命令包进 scriptblock 再 `exit $LASTEXITCODE` 透传；非 0 一律抛错并回显 stderr 尾部，
   **绝不当空源**（否则「源挂了」看起来像「今天没活」）。
3. **超时**：`TimeoutSec`（默认 30）到点 `Kill($true)` 杀进程树再抛错。一条挂死的 CLI 不能拖死整轮。
4. **stdout 只认 JSON**：首个非空字符必须是 `[` 或 `{`；否则报错并回显首 200 字符
   （CLI 把 banner / 进度日志打到 stdout 是这类源的头号故障）。子进程 stdout 按 UTF-8 解码，中文标题实测无损。
5. **信封与字段名**：顶层数组直接用；对象按 `items/records/list/data/rows` 自动找数组（含 `data.list` 里再一层），
   复杂结构用 `itemsPath='data.list'` 显式指定；字段名用 `fieldMap` 重映射，语法与 csv-file 的 `columnMap` 一致。

必填只有 `id`。缺 id 时报错会点名「第几行 / id 映射到哪个属性 / 该行实际属性」，因为这是 `fieldMap`
写错时唯一的可诊断信号。`priority` 非法降 P2、`interval` 转 int、`lastRun` 的 `DateTime` 转 ISO
全部由装配层 `ConvertTo-PatrolItem` 兜住——adapter 不重复实现归一。

### 3.3 归一后的 item

```
id=job-101  title=SCNet 队列巡检  priority=P0  intervalMin=30
currentStage=进行中  nextStep=核对队列配额  repoPath=D:\gitAll\patrol-scaffold
threadId=(null)  fake=False  lastRun=(null)
```

与 `local-json` 归一后的键集合逐键相同（`verify-command-adapter.ps1` 的 `parity:` 断言，分进程装配验的）。

---

## 4. 常见坑（按踩到的顺序）

| 症状 | 原因 | 对策 |
|---|---|---|
| `stdout 不是 JSON（首个非空字符是 'l'）` | CLI 把 banner / 进度行打到 stdout | 让 CLI 只输出 JSON（`--json` / `-o json` / `2>/dev/null`）；适配器不猜、不截取 |
| 报 `退出码 1`，但手工跑明明是 2 或 7 | `pwsh -Command` 只返回 0/1 | 模块内包 scriptblock + `exit $LASTEXITCODE` 透传真实码（本次实测修过，测试断言必须是 7） |
| `[round]` 卡住不结束 | 命令挂死、无超时 | `TimeoutSec`；到点杀进程树并抛错 |
| 只有 1 行数据时报「找不到行数组」 | 单元素 JSON 数组被解包成对象 | 先判「首个字符是 `[`」再 `@(...)`；单行对象也接受（带 id 属性即视为一条） |
| `第 1 行的 id 为空：fieldMap 把 id 映射到属性 'nope'…` | `fieldMap` 键名与源字段不一致 | 按报错里的「该行实际属性」重映射 |
| `必填参数 'ItemsPath' 为空（描述文件声明为必填）` | arg 展开成空串 | 给 `config` 一个非空默认值，或改用哨兵值（本适配器用 `.`） |
| 高级函数报 `找不到与参数名称 'ItemsPath' 匹配的参数` | `args` 键名与 `param(...)` 拼写/大小写不符 | `verify-adapter-spec.ps1` 的 `E-ARGNAME` 提交前就挡；简单函数则会**静默吞掉**，更难查 |
| 中文变乱码 | 子进程 stdout 编码 | 按 UTF-8 解码（`StandardOutputEncoding`）；mock fixture 里放中文，测试断言逐字相等 |
| 写回把源改了 | 命令型源通常不可写 | 本适配器只写本地镜像 `MirrorFile`，只写非空字段、按 id upsert、无变化不落盘；要真写源请在命令里显式实现 |
| 镜像文件每次调用都变 | 写了 `writtenAt` 之类时间戳 | 只在有变化时落盘（本次实现：`changed=0` 直接返回，字节不变） |
| `Import-PatrolProvider` 装完调用报「找不到参数 ItemsPath」 | **同一会话里先 dot-source 过该模块**：装配层按「dot-source 前后的函数正文快照」判定谁装了哪些函数，正文相同 = 认为函数已存在 → 跳过登记 | 别在同一进程混用两种装载方式；直连测试请分进程（`verify-command-adapter.ps1` 的 parity 段就是这么做的） |
| 契约自测报 `list-items() 返回 0 行` | 源真的空，或过滤条件筛空 | 空源算 FAIL 是刻意的（防止「没读到」伪装成「没有活」）；给真实样本 |
| CI 上红、本机绿 | fixture 依赖本机路径 / 网络 / 时钟 | fixture 只用 `$PSScriptRoot` 推路径、不联网、不看时间 |

---

## 5. 什么时候只加 adapter，什么时候才该动核心

判定只有一个问题：**这件事能不能只用「item 形状 + 三个槽位」表达？**

| 需求 | 只加 adapter | 要动核心 | 说明 |
|---|---|---|---|
| 换数据源（表 / 文档 / CSV / JSON / CLI / API） | ✅ | | 本次就是这一类 |
| 源字段名不同、多了信封、要翻页 | ✅ | | `fieldMap` / `itemsPath` / 模块内部分页 |
| 每行要用不同命令、不同凭据 | ✅ | | 在 `Get-PatrolItems` 里路由；item 里多带一列即可 |
| 写回源系统 | ✅ | | `Save-PatrolItems` 自己实现；本次选择「只落镜像」 |
| 命令级重试 / 限流 / 熔断 | ✅ | | 属于源的脾气，留在 adapter |
| 源里多一个字段，想带进 digest | ✅ | | `additionalProperties: true`，归一后原样保留 |
| 想给 item 增加**必填**字段或改字段类型 | | ✅ | `schemas/item.schema.json` 是契约，跨仓同源（`verify-item-contract-parity`） |
| 一轮里同时读两个源（A 源的任务派到 B 源回写） | | ✅ | 调度器一轮只装一个 provider；这是架构级需求 |
| 新增一个能力槽（通知、审批…） | | ✅ | 装配层只认 `optional.syncBack` 一个槽 |
| 换 SKIP 判据（凭据键不叫 `configPath`） | | ✅ | `adapter-contract-test.ps1` 写死了键名 |
| 让 provider 影响 due-list / 并发策略 | | ✅ | 那是第 2 层，适配器不该有话语权 |

### 本次三个「差一点就要动核心」的点（诚实记录）

1. **透传真实退出码**：本想改装配层，但装配层根本不执行命令（执行是 adapter 的事）→ 在模块内包一层，
   核心 0 行。
2. **`itemsPath` 想留空表示「自动」**：装配层把所有 `args` 当必填，空串直接抛 → 改用 `.` 哨兵，
   核心 0 行（代价是一个约定要写进文档）。
3. **同会话混用 dot-source 与 `Import-PatrolProvider`**：装配层用「函数正文快照」判断谁装了函数，
   正文相同就跳过登记 → 测试改成分进程，核心 0 行。这不是本次引入的问题，但它是一个**已知脆点**：
   以后若真要在同一进程里既直连模块又装配，就得先改装配层（届时应连带补 `verify-provider-isolation.ps1`）。

---

## 6. 度量口径（下次照这个量，别凭感觉说「适应性不错」）

1. 核心四件的 diff 必须为空：
   `git diff --numstat -- scripts/patrol-provider.ps1 scripts/patrol-loop.ps1 scripts/adapter-contract-test.ps1 schemas/item.schema.json`
2. 新增行数分四类记：descriptor / module / fixture / test（别混成一个总数，模块行数最容易被当成「成本」）。
3. 步骤数 = 从「想接一个新源」到「端到端 `due=N/N` + `digest.method=<name>`」的手工动作条数（本次 8 步）。
4. 门禁必须五条全绿：

```powershell
pwsh -NoProfile -File tests/verify-adapter-spec.ps1            # fail=0 且 selftest fail=0
pwsh -NoProfile -File scripts/adapter-contract-test.ps1        # fail=0（无凭据的家不许 SKIP 掉真实行）
pwsh -NoProfile -File tests/verify-item-contract-parity.ps1    # PASS 或 SKIP（SKIP 只表示本环境无兄弟仓）
pwsh -NoProfile -File tests/verify-provider-isolation.ps1      # fail=0
pwsh -NoProfile -File tests/verify-<name>-adapter.ps1          # fail=0
```

---

## 7. 安全边界（命令型源特有）

- 命令串来自描述文件 config / `-Values` / `PATROL_COMMAND_COMMAND`，等价于**任意代码执行**。
  只在受控配置里用；**永远不要**把源数据（表里的某列）拼进命令串——那就是注入。
- 命令在仓库根执行，`list-items()` 只允许读；写回只写本地镜像（`state/`，已被 `.gitignore` 覆盖）。
- 不落凭据：需要 token 的 CLI 让它自己读环境变量；本适配器不接收、不转存、不回显任何凭据。

---

## 8. 支持边界与 SKIP（0.2.0 实测）

> 这一节回答两个常被混为一谈的问题：**「契约自测 PASS」到底证明了什么**，以及
> **「bitable / tencent-docs 一直 SKIP，能不能发版」**。发布政策全文见 `docs/releasing.md` §5。

### 8.1 五家的当前边界

| provider | 契约自测（无凭据环境） | 已证到的深度 | 未覆盖的缺口 | 本仓离线补偿 |
|---|---|---|---|---|
| `command` | **PASS**（3 行） | 装配 → 子进程命令 → JSON 解析 → fieldMap → schema → resolve-name → 镜像写回幂等 | 真实 CLI 的鉴权/网络形态（fixture 是本地 mock） | `verify-command-adapter.ps1` 45 条断言（含退出码 7 / 超时 / banner / fieldMap 拼错） |
| `csv-file` | **PASS**（3 行） | 同上 + 列映射 / 引号逗号换行 / 写回字节保真 | 无 | `verify-csv-file-adapter.ps1` 43 条断言 |
| `local-json` | **PASS** | 装配 → 读 JSON → 归一 → schema | 无 | dry-run + `verify-provider-isolation.ps1` |
| `tencent-docs` | **SKIP** | 描述文件 / 模块 / 3 个函数存在 / 装配 | 真实鉴权、真实分页边界、列标题与视图名 | `verify-tencent-docs-adapter.ps1`：本地 mock HTTP 覆盖 2 页读取、归档行过滤、字段映射、epoch→ISO、镜像写回（14 条） |
| `bitable` | **SKIP** | 同上 | 真实 `lark-cli` 调用、字段名映射、分页 | **无**（`tests/verify-bitable-adapter.ps1` 是本地业务扩展，`.gitignore` 已排除，不随包分发） |

### 8.2 SKIP 到底跳过了什么

判据写死在 `scripts/adapter-contract-test.ps1`：`needsCredentials=true` **且** `configPath`
展开为空。跳过的是**唯一一步**——真实 `list-items()` 实跑与逐行 schema 校验。

在 SKIP 判定之前，这些检查已经发生且不会因为凭据缺失而跳过：

1. 描述文件能解析、`provider` 与文件名一致、`module` 存在且不是绝对路径；
2. 模块 dot-source 成功，`listItems` / `writeBack` / `resolveName` 三函数与 `optional.<slot>`
   声明的能力函数都存在；
3. `verify-adapter-spec.ps1` 对同一批文件的静态规格（11 键 / `${...}` / `E-ARGNAME`）全绿。

所以读法只有一个：**SKIP = 没实跑，不是没检查**；它不能当 PASS 用，也不能当 FAIL 读。

### 8.3 恢复到「实跑」的条件（不改代码）

```powershell
# 配置文件放仓外，只放定位信息 / 列映射 / 视图名，不放明文密钥
$env:PATROL_TENCENT_DOCS_CONFIGPATH = "$env:USERPROFILE\.patrol\tencent-docs.json"
pwsh -NoProfile -File scripts/adapter-contract-test.ps1 -Provider tencent-docs

# bitable 同理（键名固定 configPath）
$env:PATROL_BITABLE_CONFIGPATH = "$env:USERPROFILE\.patrol\bitable.json"
pwsh -NoProfile -File scripts/adapter-contract-test.ps1 -Provider bitable
```

环境变量名由装配层按 `<PROVIDER>_<CONFIGKEY>` 大写生成；也可以走 `-Values`。
键不叫 `configPath` 的 provider **不会** SKIP，会直接实跑——那时无凭据必红是预期行为。

### 8.4 结论：SKIP 不阻塞本次发布（附条件）

本版把 SKIP 判为**不阻塞**，理由三条，都可核：

1. **本版没改这两家的代码**：0.2.0 的变更是契约层、注册、新增 `csv-file` / `command` 与门禁；
   `BitAbleAdapter.ps1` / `tencent-docs-adapter.ps1` / 两份描述文件均未改动。拿未改动的代码要求
   新增凭据实跑，验的是环境不是发布内容。
2. **凭据不能进仓 / 不能进 CI**：密钥卫生是硬门禁（`verify-no-secrets.ps1`），为一次验收引入仓库
   secret 等于用发布流程破坏自己刚立的安全约束。
3. **收益可被离线手段替代**：`tencent-docs` 的真实代码路径已有 mock 服务覆盖；`bitable` 的缺口是
   「无离线 harness」，属已知技术债（已记在 `CHANGELOG.md` Known limits），与本版发布无关。

**下一次发布时，出现下列任一情况就必须先补离线 harness 或做一次受控实跑，SKIP 才算阻塞**：

- 该 provider 的模块、描述文件，或它依赖的装配层 / 归一函数被改动；
- `verify-adapter-spec.ps1` 对该 provider 出现 `fail` 或 `S-*`（连静态都没验完）；
- 该 provider 是本次发布的卖点（例如首次发布某家 provider）。

---

## 一页速查

```
adapters/<name>.adapter.json   11 键 + optional；provider=文件名；args 键 == 模块参数名；args 不许空串
scripts/<name>-adapter.ps1     Get-PatrolItems / Save-PatrolItems(-Items) / Resolve-ItemName(-Item)
tests/fixtures/<name>/         离线 mock：无网络、无凭据、路径相对、输出确定性
tests/verify-<name>-adapter.ps1  happy path + 每个负面分支 + 跨 provider 形状一致
核心改动                        0 行（patrol-provider / patrol-loop / adapter-contract-test / item.schema）
判定                            能用「item 形状 + 三个槽位」表达 -> 只加 adapter；否则先补契约
SKIP                            只表示「缺 configPath、没实跑 list-items」；读作没检查会误判发布风险
```
