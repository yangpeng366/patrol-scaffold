# tencent-docs 适配器规格（provider=tencent-docs）

> 按 `references/adapter-spec.md` 的 11 节填表。取证与实现由 SCNet-Max 子 agent 完成（会话 `el-id-7641-2049`，2026-11-10）；
> 接口事实来自 docs.qq.com 官方开发文档正文（逐页核对，非凭记忆），实现见 `scripts/tencent-docs-adapter.ps1`，
> 描述文件见 `adapters/tencent-docs.adapter.json`，端到端自测见 `tests/verify-tencent-docs-adapter.ps1`。
>
> 两条要注意的边界：
> 1. 该接口**仅支持「在线表格内的 smartsheet 子表」**，独立「智能表格」文件不适用（官方概念页原文）。
> 2. 企业微信 `qyapi.weixin.qq.com/.../smartsheet/*` 是**另一套**接口，不可与开放平台混用。

---
## 规格正文（按 `references/adapter-spec.md` 的 11 节填）

## 0. 先决判断

- [x] 周期性：巡检每 30 分钟一轮，轮内按行 `intervalMin` 过滤
- [x] 「要做什么」能落成行：智能表格一条 record = 一行 = 一个任务方向
- [x] 每行是有界工作（一段有界 agent 工作，不是长期跑的任务）
- [x] 行列里能读出 id / 标题 / 优先级 / 间隔（`recordID` / 项目名 / 优先级 / 巡检间隔(分钟)）
- [x] 补充硬条件（该 provider 特有）：智能表格必须是**在线表格内的 smartsheet 子表**，独立「智能表格」文件不适用——官方概念页明确写「该接口目前仅支持用于表格内的 smartsheet 子表」

## 1. 源与触发映射（Source → Trigger）

| 项 | 填 |
|---|---|
| 数据源是什么 | 腾讯文档「在线表格」内的 Smartsheet 子表；一条记录 = 一行任务 |
| 一次「读」的范围 | 指定 `fileID` + `sheetID` 的子表；可选 `viewID` 限定视图；`offset/limit` 分页（`limit ≤ 100`），按 `hasMore/next` 续取 |
| 触发方式 | Windows 计划任务 `CodexPatrol-tencent-docs`（`-Once` + `IgnoreNew`，首选）；常驻则 nssm |
| 触发间隔 | 每 30 分钟一轮（轮内再按行 `intervalMin` 过滤，未到期不派） |
| 单实例保证 | 全局 mutex `Global\patrol-tencent-docs` + 轮次硬超时 1500s（超时让位下次触发，不堆叠） |

**规则复核**：触发层不认识厂商——计划任务只调 `pwsh -File scripts/patrol-loop.ps1 -Once -DryRun`，provider 由 `PATROL_ADAPTER` 决定，换源不动触发。

## 2. 配置 schema（字段 / 类型 / 默认 / 健康度）

**A. 描述文件层（`adapters/tencent-docs.adapter.json` 的 `config`，可被 `PATROL_TENCENT_DOCS_*` 覆盖）**

| 键 | 类型 | 默认 | 健康度判据 |
|---|---|---|---|
| `configPath` | string（路径） | 空 | 非空且文件存在即「已接入」；**为空 = 契约自测 SKIP（未接入），不是故障** |
| `mirrorFile` | string（相对仓根） | `state/tencent-docs-mirror.json` | 父目录可写；落盘后文件可解析为 JSON 数组 |
| `syncBack` | string（布尔字面量） | `false` | 仅 `true/1/yes/on` 视为开；其余一律写保护 |

**B. 配置文件层（`configPath` 指向的 JSON，含定位信息与列映射，不含任何凭据）**

| 键 | 类型 | 默认 | 健康度判据 |
|---|---|---|---|
| `fileId` | string | 空 | 非 `""`，且含 `$` 形如 `300000000$AAAA…`；空则回退 `encodedId` |
| `encodedId` | string | 空 | `docs.qq.com/sheet/D…` 里 `D` 开头那段；给了就能换 `fileId` |
| `sheetId` | string | 空 | 非空（取链接 `?tab=BB0000`） |
| `viewId` | string | 空 | 空 = 全表；非空则只读该视图 |
| `pageSize` | int | `100` | 1–100（官方 `limit` 上限 100；越界自动夹回 100） |
| `apiBase` | string | `https://docs.qq.com` | 可解析为绝对 URI；仅供联调/离线假服务器 |
| `syncBack` | bool | `false` | 写回第一道门（配置开） |
| `excludeStages` | string[] | `[]` | 命中 `当前阶段` 的行不进入巡检 |
| `fields` | object | 见 §8 | 每个值非空且与表头完全一致（含空格/括号） |
| `fieldKinds` | object | `{interval:number, fake:checkbox, lastRun:text}` | 取值为 `text`/`number`/`checkbox`/`date` |

**C. 凭据（只从环境变量，绝不入描述文件、不落盘、不打印）**

| 环境变量 | 必需性 | 说明 |
|---|---|---|
| `TENCENT_DOCS_CLIENT_ID` | 是 | 开放平台分配的 app_id / Client ID，同时作为 `Client-Id` 头 |
| `TENCENT_DOCS_CLIENT_SECRET` | 应用级账号/刷新令牌时必需 | 只用于换令牌，绝不进 URL 日志 |
| `TENCENT_DOCS_ACCESS_TOKEN` | 三选一（直给） | 已由别处换好的令牌 |
| `TENCENT_DOCS_OPEN_ID` | 直给令牌时必需 | `Open-Id` 头 |
| `TENCENT_DOCS_REFRESH_TOKEN` | 可选 | 用户授权路径：走 `grant_type=refresh_token` |

**规则复核**：凭据不入仓（只入环境变量）；外部依赖不写死本机绝对路径（本 provider 无外部 helper 依赖）；健康度判据是看门狗可读的布尔量（`configPath` 存在 + `fileId/sheetId` 非空 + `client_id/secret` 存在）。

## 3. 触发器构造

- [x] 计划任务名：`CodexPatrol-tencent-docs`
- [x] 轮次硬超时：`RoundTimeoutSec = 1500`
- [x] 并发上限：`MaxPatrolChildren = 3`（并发上限，非「每轮取 N 条」——后者饿死 P2）
- [x] 失败重置：`MaxConsecutiveFailures = 3` 后 `threadId` 置空重建（防死线程空转）
- [x] 频控预算：一次读 + 每行一次写 ⇒ 100 行/轮约 101 次调用，逼近 fileID 150 次/分；因此**一轮行数上限建议 ≤ 100**，写回按 50 条/批合并

## 4. 接收范围（scope）

| 项 | 填 |
|---|---|
| 哪些行进入巡检 | `fileID + sheetID` 子表全部记录；给了 `viewID` 则只取该视图 |
| 哪些行明确排除 | `当前阶段` ∈ `excludeStages`（默认 `["已完成","归档"]`）；适配器层过滤（契约无 status 字段，不能指望主循环） |
| 每次最多取多少 | 100 行/页；分页续取，适配器内硬护栏 50 页（≈5000 行）后抛错停手，不静默截断 |
| 假数据/演练开关 | `假数据模式` 列（复选框）→ item.fake；worker 见到 `fake=true` 只产样本不真跑 |

## 5. 回复通道（Channel）

| 项 | 填 |
|---|---|
| 结果写回哪 | 源表五列：`当前阶段`、`外部成就`、`下一步`、`codex_thread_id`、`最近巡检时间`（全部走 `updateRecords`，按 `recordID` 定位，局部更新） |
| 写回开关 | **双重门**：配置文件 `syncBack: true` **且** 描述文件参数 `syncBack=true`（`PATROL_TENCENT_DOCS_SYNCBACK=true` 或显式 `-Values`）；任一为假 → 零远端写入 |
| 本地镜像 | 无论写回开关如何，`Save-PatrolItems` 都原子写 `state/tencent-docs-mirror.json`（gitignored），供 digest/复盘；镜像内不含凭据 |
| 人工通知 | 飞书机器人 / 企业微信 webhook，只在「成/阻」各报一次；**通知不进适配器**，与源解耦 |
| 通道解耦 | 源是腾讯文档、通知走飞书是允许的（本仓 bitable 实例即此形态） |

## 6. 线程上下文（Thread）

- [x] 行内 `codex_thread_id` 列：worker 续跑用它（空则新建）
- [x] 回写把新线程 id 推回该列，人能接手
- [x] 连续失败 3 次后置空重建（不是无限续跑死线程）
- [x] `最近巡检时间` 同时回写，作为下一轮 due 判定的 `lastRun`（**这是「立刻重跑 due=0」的前提**）

## 7. 策略（Policy）

- [x] 源系统默认**只读**：`syncBack` 双门默认关；`needsCredentials=true` 只用于读
- [x] worker 只做有界、可逆的本地改动；不发布、不动外部系统，除非该行显式声明
- [x] 关联器只读 `git status/log`，不 commit/push
- [x] 令牌只进内存缓存（进程内、按 `apiBase` 分桶），不写文件
- [x] 异常信息只报 `HTTP 码 / ret / msg`，**不回显含 `client_secret` 的 URI**、不回显令牌

## 8. 执行变量

| 变量 | 来源（列） | 用途 |
|---|---|---|
| `title` | 项目名 | worker prompt 标题、digest 可读名 |
| `repoPath` | 仓库路径 | worker 工作目录 |
| `description` | 简要描述 | prompt 背景 |
| `nextStep` | 下一步 | prompt 本轮目标 |
| `priority` | 优先级（请填 `P0/P1/P2`） | 排序（P0 先）；非枚举值会被 `ConvertTo-PatrolItem` 降为 `P2` |
| `intervalMin` | 巡检间隔(分钟) | 到期判定（数字列；空/0 = 停跑，不进入调度） |
| `threadId` | codex_thread_id | 续跑 |
| `fake` | 假数据模式（复选框） | 演练开关 |
| `lastRun` | 最近巡检时间（文本 ISO 或日期毫秒） | due 判定，空=到期 |
| `currentStage` / `achievement` | 当前阶段 / 外部成就 | 回写 + digest |

默认列名（`fields` 可覆盖）：`项目名 / 仓库路径 / 简要描述 / 下一步 / 优先级 / 巡检间隔(分钟) / codex_thread_id / 假数据模式 / 最近巡检时间 / 当前阶段 / 外部成就`。

**规则复核**：prompt 必须带「时间自控：超时主动拆分到下一轮」，避免一行跑不完拖死整轮（本仓 `patrol-loop.ps1` 的真实 worker 钩子注释即此写法）。

## 9. 插件入口与循环（适配器模块）

```powershell
function Get-PatrolItems   { param([Parameter(Mandatory)][string]$ConfigPath, [string]$ApiBase = '') }   # list-items()
function Save-PatrolItems  { param([Parameter(Mandatory)][string]$TasksFile, [Parameter(Mandatory)]$Items,
                                   [string]$ConfigPath = '', [string]$SyncBack = 'false', [string]$ApiBase = '') }  # write-back()
function Resolve-ItemName  { param($Item) }                                                              # resolve-name()
```

- 与 `BitAbleAdapter` 的签名对应关系：`BitableConfigPath → ConfigPath`、`Identity → ApiBase`（都是「第二可选参数 = 连接方式」，本 provider 的身份由令牌决定，不需要 `--as user` 这类开关）；`Save-PatrolItems(TasksFile, Items, …)` 前两个必需参数位置一致；`Resolve-ItemName(Item)` 完全一致。
- 模块路径写进描述文件 `module`；缺函数 → `Import-PatrolProvider` 装配期就抛「模块未定义 X（契约不满足）」，不等运行时。
- 内部流程：`读配置 → 取令牌（缓存）→ 解析 fileID（必要时 converter）→ 分页 getRecords → 逐条归一 → 按 excludeStages 过滤`；写回：`本地镜像（原子写）→ 双门校验 → 按 50/批 updateRecords`。
- 形状归一仍由 provider 层 `ConvertTo-PatrolItem` 收口（本适配器不重复造轮子，只把 `values` 摊平成标量/ISO 串）。
- **重要约束**：`Get-PatrolProviderItems` 会把描述文件声明的**每个** `listItems.args` 当必填（空值直接抛）。因此凭据**绝不能**声明进 `args`——否则「没配凭据」会变成装配期硬失败，而不是可 SKIP 的配置问题。

## 10. 插件注册（描述文件）

`adapters/tencent-docs.adapter.json`（完整内容见第二部分）。注册生效点：

- `Get-PatrolAdapterDescriptor` 读 `adapters/<provider>.adapter.json`（`<provider>` 即 `PATROL_ADAPTER`）
- `Import-PatrolProvider` dot-source 模块并把函数提升到 script 作用域，再校验 `listItems/writeBack/resolveName` 三函数存在
- 取值优先级：描述文件默认 < `-Values` < 环境变量 `PATROL_<PROVIDER>_<KEY>`（provider 名里的 `-` → `_`，故为 `PATROL_TENCENT_DOCS_*`）
- `optional` 留空对象：本 provider 不需要额外能力槽（写回已由 `writeBack` 承担）

## 11. 测试清单

**必做（自动化）**

- [ ] `pwsh -File scripts/adapter-contract-test.ps1 -Provider tencent-docs` → 未配环境时 **SKIP**；配齐后 **PASS**
- [ ] `pwsh -File scripts/patrol-loop.ps1 -TasksFile <样本> -Once -DryRun`（`PATROL_ADAPTER=tencent-docs`）→ `due/completed` 符合预期
- [ ] digest JSON 的 `method` == `tencent-docs`（取 `$AdapterName`，非写死旧名）
- [ ] 立刻重跑一轮 → `due=0`（**须开写回**，否则源里的 `最近巡检时间` 未更新，第二轮仍全部 due）

**必做（人工）**

- [ ] 凭据缺失时是 SKIP 而不是 FAIL（判据：不设 `PATROL_TENCENT_DOCS_CONFIGPATH`）
- [ ] 只读模式下游系统零写入（`syncBack` 双门任一关；抓包/审阅日志确认无 `updateRecords`）
- [ ] 写回开关：`config.syncBack=true` 且 `syncBack=true`，两个都开才写（四种组合逐一验）
- [ ] 令牌不出现在任何输出/日志/镜像文件里（`Select-String` 扫 `access_token`、`client_secret`）

**不该有的**

- [ ] 描述文件里没有本机绝对路径（本文件只有 `state/...` 相对路径）
- [ ] 仓里没有 token / key / 口令（凭据只走环境变量）
- [ ] 仓里没有运行时产物（镜像落 `state/`，已 gitignore）

**完成标准**：新增 provider = 两个文件 + 一次契约自测 PASS；若发现还得改 `patrol-loop.ps1`，说明契约有缺口，先补契约。

---


---

## 落地与待办（原文）

# 四、契约自测怎么跑、预期输出、待办

## 4.1 落地两步

```powershell
# 步骤 1：落两个文件（新增，不碰其它文件）
#   adapters/tencent-docs.adapter.json   ← 第二部分全文
#   scripts/tencent-docs-adapter.ps1     ← 第三部分全文

# 步骤 2：provider 配置文件放仓外（示例；只放定位信息与列映射）
#   %USERPROFILE%\.patrol\tencent-docs.json
```

`%USERPROFILE%\.patrol\tencent-docs.json` 示例：

```json
{
  "fileId": "300000000$AAAAAAAAA",
  "encodedId": "",
  "sheetId": "BB0000",
  "viewId": "",
  "pageSize": 100,
  "syncBack": false,
  "excludeStages": ["已完成", "归档"],
  "fields": {
    "title": "项目名",
    "repoPath": "仓库路径",
    "description": "简要描述",
    "nextStep": "下一步",
    "priority": "优先级",
    "interval": "巡检间隔(分钟)",
    "threadId": "codex_thread_id",
    "lastRun": "最近巡检时间",
    "currentStage": "当前阶段",
    "achievement": "外部成就"
  },
  "fieldKinds": { "interval": "number", "fake": "checkbox", "lastRun": "text" }
}
```

## 4.2 三条命令与预期输出

**① 只读验收（不带任何环境变量）——应 SKIP**

```powershell
pwsh -File scripts/adapter-contract-test.ps1 -Provider tencent-docs
```

预期：

```
[SKIP] tencent-docs  provider=tencent-docs 需凭据/配置（configPath 未给），跳过实跑
summary pass=0 skip=1 fail=0
```

`SKIP` 的判定来自脚本内 `if ($needsCred -and -not $cfgPath)`，而 `configPath` 由描述文件默认 `""` + 环境变量 `PATROL_TENCENT_DOCS_CONFIGPATH` 合并得到。**所以「凭据缺失」在这把尺子下的表达方式是「不给 configPath」**；若给了 configPath 但缺 secret，适配器会抛「缺凭据…」→ 记为 FAIL（这是配置错误，不是契约问题，错误消息会点名缺哪个环境变量）。

**② 真跑验收（配齐环境变量）——应 PASS**

```powershell
$env:TENCENT_DOCS_CLIENT_ID     = '<app_id>'
$env:TENCENT_DOCS_CLIENT_SECRET = '<app_secret>'
$env:PATROL_TENCENT_DOCS_CONFIGPATH = "$env:USERPROFILE\.patrol\tencent-docs.json"
pwsh -File scripts/adapter-contract-test.ps1 -Provider tencent-docs
```

预期：

```
[PASS] tencent-docs  items=3
summary pass=1 skip=0 fail=0
```

PASS 的四道关（脚本实际做的事）：装配成功 → `list-items()` 实跑 → 每行过 `schemas/item.schema.json` → `resolve-name()` 非空。

**③ 主循环不改一行地跑一轮**

```powershell
$env:PATROL_ADAPTER = 'tencent-docs'
pwsh -File scripts/patrol-loop.ps1 -Once -DryRun
```

预期：

```
[round] due=3/3 maxChildren=2 dryRun=True
[worker] done rUg1ia dur=0.15s -> dry-run: 模拟完成 [项目名] ...
[done] digest: .../scripts/downloads/patrol-<stamp>.json
```

验收点：`due` = 未到期过滤后的行数；digest 里 `method` 字段为 `tencent-docs`；镜像落 `state/tencent-docs-mirror.json`。

**④「立刻重跑 due=0」有个前提**：`lastRun` 存在**源表**里，而 `patrol-loop` 读的是源。所以必须开写回（配置文件 `syncBack: true` + `PATROL_TENCENT_DOCS_SYNCBACK=true`）才有 `due=0`；写回关着时第二轮仍全 due —— 这不是 bug，是「源是唯一事实」的必然结果。

**FAIL 的常见形态（都是明确可诊断的）**

| 输出 | 含义 | 处理 |
|---|---|---|
| `list-items() 返回 0 行` | 子表为空，或 `excludeStages` 把行全滤掉 | 至少留 1 条未归档记录 |
| `tencent-docs: 缺凭据…` | 无 `CLIENT_ID/SECRET` 也无直给令牌 | 设环境变量 |
| `tencent-docs: ret=37019 msg=…` | 令牌过期/错误 | 重换令牌；检查 `OPEN_ID` 与令牌是否配套 |
| `HTTP 401`（换令牌阶段） | `client_id/secret` 不匹配或应用未过审 | 开放平台后台核对 |
| `字段 'priority' 类型不符` 之类 | 归一化没兜住（几乎不会出现，`ConvertTo-PatrolItem` 已收口） | 查 `fields` 映射与列类型 |

## 4.3 必须由你在腾讯侧提供的信息清单

| # | 信息 | 从哪拿 | 用在哪 |
|---|---|---|---|
| 1 | `app_id`（= Client ID） | 腾讯文档开放平台 → 创建第三方应用后分配 | `TENCENT_DOCS_CLIENT_ID` + `Client-Id` 头 |
| 2 | `app_secret`（= Client Secret） | 同上 | `TENCENT_DOCS_CLIENT_SECRET`，只进环境变量 |
| 3 | 应用**审核状态** | 开放平台后台 | 未过审时所有 OpenAPI 调用会失败 |
| 4 | `file_id` 或 `encoded_id` | 表格链接 `docs.qq.com/sheet/D<encodedId>?tab=<sheetId>`；`file_id` 需用 converter（`type=2`）换算，或从「新建文档」返回值取 | 配置 `fileId` / `encodedId` |
| 5 | `sheet_id` | 链接里 `?tab=BB0000` 的 `BB0000`；或多子表时用「查询子表」逐个确认 | 配置 `sheetId` |
| 6 | 授权 scope | 开放平台 → 应用权限：至少 **`scope.smartsheet`**（记录读写）；应用级账号另需 **`scope.auth.account`**；用 encodedID 换算需 `scope.drive.readonly` | 申请并等审核 |
| 7 | 用户 `Open ID`（仅用户授权路径） | 换令牌响应的 `user_id`，或「获取用户信息」接口 | `TENCENT_DOCS_OPEN_ID` |
| 8 | 表头 11 列的实际列名与**字段类型** | 智能表格客户端 | 配置 `fields` / `fieldKinds`（列名必须逐字一致，含括号与空格） |
| 9 | 视图 ID（可选） | 链接 `&viewId=vFyrAM` | 配置 `viewId`，只巡该视图 |
| 10 | 是否允许写回 | 业务决策 | 配置文件 `syncBack` + `PATROL_TENCENT_DOCS_SYNCBACK` |

**注意**：智能表格必须是**在线表格里的 smartsheet 子表**（官方概念页明确限制）；一个独立的「智能表格」文件不能按本路径调记录接口。应用级账号还有 1G 免费空间、不能前端登录等限制。

## 4.4 待核实清单（不臆造，给核实方法）

| # | 待核实项 | 现状处理 | 核实方法 |
|---|---|---|---|
| 1 | `sort`（`Array(Sort)`）的元素结构官方未展开 | 代码不传 `sort`，只按 `offset/limit` 分页，排序放在本地（`patrol-loop` 按优先级排） | 读 `https://docs.qq.com/open/document/app/openapi/v2/smartsheet/record/params.html#getrecordsrequest`；或传 `{"sort":[{"fieldTitle":"优先级"}]}` 试一次看 `ret` 与顺序 |
| 2 | `updateRecords` 单次批量上限 | 保守 50 条/批 | 10→50→100→200 递增批量，观察 `ret`/错误码与耗时 |
| 3 | 日期字段**写入**编码（毫秒字符串 vs 数值） | `fieldKinds.lastRun=date` 时写毫秒**字符串**（与官方读样例 `'日期':'1640150219265'` 同形）；默认建议该列用**文本**字段写 ISO | 写一条后立刻 `getRecords` 读回，比对值是否被接受；若 `ret!=0` 改数值或改文本列 |
| 4 | 复选框写入 `true/false` 直传 | 按布尔直传 | 同法写回读回 |
| 5 | 应用级账号令牌能否直接调 `scope.smartsheet` 接口（该令牌只声明 `scope.auth.account`） | 代码两条路径都支持（直给令牌 / 应用级账号）；若 403 就改用用户授权令牌 | 后台同时勾选两项后调一次 `getRecords`，看 `ret` 与错误码 |
| 6 | 记录值的完整类型表（公式/关联/人员等列） | 只处理 text/number/checkbox/date/link/image 的分段读取 | `https://docs.qq.com/open/document/app/openapi/v2/smartsheet/record/params.html` 与「字段接口 `get_fields`」对照 |

## 4.5 落地检查表（提交前逐条打勾）

- [x] 只新增两个文件，`patrol-loop.ps1` / `patrol-provider.ps1` / `adapter-contract-test.ps1` 零改动
- [x] 描述文件无本机绝对路径（只有 `state/…` 相对路径）
- [x] 无 token / secret / 口令入库；异常信息不含 URI 与令牌
- [x] 运行时产物落 `state/`（已 gitignore），不落 `scripts/`
- [x] 默认只读；写回需**两个**开关同时为真
- [x] 凭据缺失 → SKIP（不设 `configPath` 时），不是 FAIL
- [x] `kind=api`、`needsCredentials=true`、`needsNetwork=true` 与实际行为一致

