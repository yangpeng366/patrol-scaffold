# 新增一个 provider：两个文件、三条门禁

> 本文是**操作手册**：照着写，落到 `adapters/<name>.adapter.json` + `scripts/<name>-adapter.ps1` 两个文件，
> 过 `tests/verify-adapter-spec.ps1` 与 `scripts/adapter-contract-test.ps1`，一个新数据源就接上了，
> `patrol-loop.ps1` / `patrol-provider.ps1` / `schemas/item.schema.json` 一行不改。
> 「这个源该不该用本骨架」的业务判断填表在 `references/adapter-spec.md`（11 节）；本文只讲代码怎么接。
> 所有对照都以仓内四个真实 provider（`csv-file` / `local-json` / `tencent-docs` / `bitable`）为准。

---

## 0. 边界：新增一律只动两个文件

| 类别 | 文件 | 说明 |
|---|---|---|
| 必须新增 | `adapters/<name>.adapter.json` | 描述文件（声明式注册） |
| 必须新增 | `scripts/<name>-adapter.ps1` | 模块（三个契约函数的实现） |
| 建议新增 | `tests/verify-<name>-adapter.ps1` | 本 provider 的离线自测（可无） |
| 建议新增 | `references/<name>-adapter.md` | 本 provider 的 11 节规格（可无） |
| **禁止修改** | `scripts/patrol-loop.ps1` | 调度器不认识厂商 |
| **禁止修改** | `scripts/patrol-provider.ps1` | 装配契约；改它等于改所有 provider |
| **禁止修改** | `schemas/item.schema.json` | item 契约唯一事实源 |
| **禁止修改** | 别的 provider 的描述文件/模块 | 同名函数靠装配层隔离，不靠改名 |

要改骨架才接得上，说明契约有缺口：先补契约（并同步本文与 `references/adapter-spec.md`），再改骨架。

---

## 1. 两个文件叫什么、放哪里

- **描述文件**：`adapters/<provider>.adapter.json`。文件名（去掉 `.adapter.json`）**就是** provider 名，
  也是 `PATROL_ADAPTER` 的取值、`Import-PatrolProvider -Provider` 的取值。
  `verify-adapter-spec.ps1` 用 `E-FILENAME` 卡这一条，`adapter-contract-test.ps1` 另有一句
  「描述文件 provider='x' 与文件名 'y' 不一致」。
- **模块路径**：写在描述文件的 `module` 里，**相对仓库根**，不能是绝对路径、不能含 `..`、必须是已存在的文件
  （后缀非 `.ps1` 只 WARN）。约定叫 `scripts/<provider>-adapter.ps1`，但**约定不是规则**——`bitable` 就是
  `scripts/BitAbleAdapter.ps1`。校验只看 `module` 指向的文件在不在、能不能 dot-source。
- **provider 名**只建议用 `小写字母/数字/-/_/.`（`W-PROVIDER` 只是警告）。名字里的非字母数字会变成环境变量名里的 `_`。

四个真实 provider 的对照（照抄一行即可开工）：

| provider | 描述文件 | module | kind | needsCredentials | needsNetwork |
|---|---|---|---|---|---|
| `csv-file` | `adapters/csv-file.adapter.json` | `scripts/csv-file-adapter.ps1` | `file` | `false` | `false` |
| `local-json` | `adapters/local-json.adapter.json` | `scripts/local-json-adapter.ps1` | `file` | `false` | `false` |
| `tencent-docs` | `adapters/tencent-docs.adapter.json` | `scripts/tencent-docs-adapter.ps1` | `api` | `true` | `true` |
| `bitable` | `adapters/bitable.adapter.json` | `scripts/BitAbleAdapter.ps1` | `cli` | `true` | `true` |

`kind` 与 `needsNetwork` **只是声明**：`verify-adapter-spec.ps1` 校验 `kind ∈ file|cli|api`，运行期没有任何代码
按 `kind`/`needsNetwork` 分支。真正影响行为的是 `needsCredentials`（见 §7 的 SKIP 口径）。

---

## 2. 描述文件：必需的 11 个键 + `optional`

`verify-adapter-spec.ps1` 的 `$RequiredKeys` 就是下面这张表（顺序即报错顺序）：

| 键 | 类型 | 校验 | 谁来读 |
|---|---|---|---|
| `provider` | string | 非空；与文件名一致；全局唯一 | 装配层按它找文件（其实按文件名找）；spec 检查查唯一性 |
| `title` | string | 非空（`E-EMPTY`） | 人读；运行期不读 |
| `module` | string | 非空；相对仓库根；存在；无 `..` | `Import-PatrolProvider` dot-source |
| `kind` | string | `file` \| `cli` \| `api`（`E-ENUM`） | 仅声明 |
| `needsCredentials` | **bool** | 必须是 JSON `true`/`false` | `adapter-contract-test.ps1` 决定 SKIP |
| `needsNetwork` | **bool** | 必须是 JSON `true`/`false` | 仅声明 |
| `description` | string | 空只 WARN（`W-DESC`） | 人读 |
| `config` | object | 值必须是标量（非标量 WARN `W-CONFIG`） | 提供 `${...}` 的默认值 |
| `listItems` | object | `{ function, args }`，`function` 非空且在模块里存在 | `Get-PatrolProviderItems` |
| `writeBack` | object | 同上 | `Save-PatrolProviderItems` |
| `resolveName` | object | 同上 | `Resolve-PatrolProviderName` |
| `optional` | object | **缺键只 WARN**；写了就必须是对象，子槽必须是 `{ function, args }` | 目前只消费 `optional.syncBack` |

三条硬口径（`verify-adapter-spec.ps1` 文件头已写死，这里复述以免踩）：

1. **未知顶层键 = FAIL**（`E-UNKNOWN`）。把 `writeBack` 拼成 `writeback`，装配层会静默按「没有这个槽」走，
   漂移检查就失去意义，所以宁红不灰。
2. **缺 `optional` 键 = WARN**（`W-OPTIONAL`），因为装配层把 `$null` 当「无该能力」。但请照规格写 `"optional": {}`。
3. **`args` 的值必须是字符串**（`E-TYPE`）。数字/布尔要写成 `"${...}"` 或字符串字面量，装配层一律按字符串注入。

可以直接抄的最小样例（`adapters/csv-file.adapter.json` 原文）：

```json
{
  "provider": "csv-file",
  "title": "本地 CSV 文件",
  "module": "scripts/csv-file-adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "数据源是一个本地 CSV 文件，一行一条任务方向：Import-Csv 解析、列映射可配置、必填列缺失即报错、写回只改目标行的指定列并保留其余字节。零网络零凭据，适合离线/内网与教学。",
  "config": {
    "csvPath": "scripts/sample-tasks.csv",
    "columnMap": "id=id;title=title;priority=priority;interval=interval;status=status;action=action;note=note"
  },
  "listItems": {
    "function": "Get-PatrolItems",
    "args": { "CsvPath": "${csvPath}", "TasksFile": "${tasksFile}", "ColumnMap": "${columnMap}" }
  },
  "writeBack": {
    "function": "Save-PatrolItems",
    "args": { "CsvPath": "${csvPath}", "TasksFile": "${tasksFile}", "ColumnMap": "${columnMap}" }
  },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
```

带能力槽的样例见 `adapters/bitable.adapter.json`：`optional.syncBack` 把 `Sync-BitableRoundResult` 挂上，
`config.sync_back`（读取方在外部 helper 里）与显式 `-SyncBack` 双门才真写远端。

---

## 3. 模块：必须定义哪些函数、签名长什么样

### 3.1 四个函数名是硬契约

```powershell
function Get-PatrolItems  { param(...) }   # list-items()
function Save-PatrolItems { param(...) }   # write-back()
function Resolve-ItemName { param($Item) } # resolve-name()
function <能力函数>       { param(...) }   # 仅当描述文件写了 optional.<slot> 时（当前唯一槽：syncBack）
```

函数名**必须**是这三个（能力槽函数名自定，但要在 `optional.<slot>.function` 里点名）。
四家 provider 都用同一组名字不冲突：`Import-PatrolProvider` 把模块函数提升到脚本作用域并记进
`ModuleFns`，每次 `Get-/Save-/Resolve-PatrolProvider*` 调用前由 `Install-PatrolProviderFunctions`
按 provider 复位（见 `tests/verify-provider-isolation.ps1` 的回归）。

### 3.2 装配层怎么调用（决定了参数名）

| 描述文件槽 | 装配层实际调用（`scripts/patrol-provider.ps1`） | 模块函数必须接受 |
|---|---|---|
| `listItems` | `& $fn @args` | 描述文件里 `args` 的每个键都得是它的参数名 |
| `writeBack` | `& $fn @args -Items $Items` | 额外必须有 `-Items` 参数 |
| `resolveName` | `& $fn @args -Item $Item` | 额外必须有 `-Item` 参数 |
| `optional.syncBack` | `& $fn @args -Item $Item` | 额外必须有 `-Item` 参数 |

`-Items` / `-Item` 是**写死在装配层**的，描述文件的 `args` 里不要写它们（写了会被展开成另一个同名参数）。

### 3.3 真实签名对照（照着选一种）

| provider | list-items | write-back | resolve-name |
|---|---|---|---|
| `csv-file` | `Get-PatrolItems([string]$CsvPath='', [string]$TasksFile='', [string]$ColumnMap='')` | `Save-PatrolItems([string]$CsvPath='', [string]$TasksFile='', [Parameter(Mandatory)]$Items, [string]$ColumnMap='')` | `Resolve-ItemName($Item)` → `$Item.title` |
| `local-json` | `Get-PatrolItems([Parameter(Mandatory)][string]$TasksFile)` | `Save-PatrolItems([Parameter(Mandatory)][string]$TasksFile, [Parameter(Mandatory)]$Items)` | `$Item.title` |
| `tencent-docs` | `Get-PatrolItems([Parameter(Mandatory)][string]$ConfigPath, [string]$ApiBase='')` | `Save-PatrolItems([Parameter(Mandatory)][string]$TasksFile, [Parameter(Mandatory)]$Items, [string]$ConfigPath='', [string]$SyncBack='false', [string]$ApiBase='')` | `$Item.title`，空则回退 `$Item.id` |
| `bitable` | `Get-PatrolItems([Parameter(Mandatory)][string]$BitableConfigPath, [string]$Identity='user')` | `Save-PatrolItems([Parameter(Mandatory)][string]$TasksFile, [Parameter(Mandatory)]$Items)` | `$Item.title` |
| `bitable`（`optional.syncBack`） | — | — | `Sync-BitableRoundResult([Parameter(Mandatory)][string]$BitableConfigPath, [Parameter(Mandatory)]$Item, [string]$Identity='user')` |

`resolveName` 的四家实现都是 `param($Item)`：**不要**给它加 `[Parameter(Mandatory)]`，装配层已经把
`-Item` 按名字传进去了，再加 Mandatory 只会让空 item 从「返回空」变成「抛错」。

### 3.4 一个必须知道的坑：args 名写错未必报错

`verify-adapter-spec.ps1` **不校验** `args` 的键是否等于模块参数名（它只校验 `${占位}` 能在 `config` 里解析）。
参数名对不上时：

- 模块函数是**高级函数**（参数上带任何 `[Parameter(...)]` 属性）→ 实跑时报
  `找不到与参数名称 'CsvPath' 匹配的参数。`（zh-CN PowerShell 原文；en-US 为
  `A parameter cannot be found that matches parameter name 'CsvPath'.`）
- 模块函数是**简单函数**（`param([string]$X)` 无属性）→ 多出来的具名参数被静默收进 `$args`，
  **不报错也不生效**，你的默认值悄悄接管。

所以「参数名与 `args` 键名逐字对齐」只能靠 §7 的契约自测实跑来兜底，别指望静态检查。

---

## 4. `${...}` 占位符从哪里取值

`Import-PatrolProvider` 先合并出一份 `Values`，`Expand-PatrolAdapterArgs` 再做**纯文本替换**
（`$v.Replace('${key}', value)`）。合并顺序（后者覆盖前者）：

1. **描述文件 `config` 的默认值**（一律 `[string]` 强转）
2. **调用方 `-Values`**（只采纳非 `$null` 且非空串的键）
   - `patrol-loop.ps1` 固定注入两个：`tasksFile`（= `-TasksFile`）与 `configPath`（= `-BitableConfigPath`，默认空）
   - `adapter-contract-test.ps1` 只注入 `tasksFile`
3. **环境变量 `PATROL_<PROVIDER>_<KEY>`**（最高优先级；provider 与 key 里的非字母数字全部替换成 `_` 再转大写）
   - `csv-file` + `csvPath` → `PATROL_CSV_FILE_CSVPATH`
   - `csv-file` + `columnMap` → `PATROL_CSV_FILE_COLUMNMAP`
   - `tencent-docs` + `configPath` → `PATROL_TENCENT_DOCS_CONFIGPATH`

规则与症状：

- 占位符**拼错**（`${csvpath}` vs 键 `csvPath`）→ 替换不命中，函数收到的是字面量 `${csvpath}`。
  静态检查会先红：`E-PLACEHOLDER ... 的占位 ${csvpath} 在 config 里找不到（config 可用键：...）`。
- `config` 里**没有**这个键 → 同上 `E-PLACEHOLDER`。跨 provider 共享的只有 `${tasksFile}` 一个例外，
  因为装配层对所有 provider 都注入它（`verify-adapter-spec.ps1` 的 `$PlaceholderException`）。
- 展开后**某个参数是空串** → `Get-PatrolProviderItems` 直接抛
  `必填参数 'ConfigPath' 为空（描述文件声明为必填）`。它把「所有 args 都当必填」，
  所以别在 `args` 里挂一个「可能有值也可能没有」的可选键——要么给 `config` 默认值，要么放进 `optional`。
- 占位符**未闭合**（`${csvPath`）→ `E-PLACEHOLDER ... 的占位未闭合`。
- `args` 的值不是字符串（`"Limit": 100`）→ `E-TYPE ... args.Limit 必须是字符串`。

写模块时要防御的是「占位符没被替换」这一种真实情况：`csv-file-adapter.ps1` 的
`Resolve-PatrolCsvPath` 用 `$tasks -notmatch '^\$\{'` 把仍然带 `${` 的值当「没给」处理，
而不是拿 `${csvPath}` 去 `Test-Path`。

---

## 5. item 形状：归一在装配层做，适配器不用造轮子

适配器的 `list-items()` 返回什么形状都行（`PSCustomObject` / hashtable / 数组），
`Get-PatrolProviderItems` 会逐条过 `ConvertTo-PatrolItem`：

| 字段 | 归一规则 |
|---|---|
| `id` | 必须有，缺则抛 `ConvertTo-PatrolItem: item 缺 id` |
| `title` | 空则回退 `id` |
| `priority` | 去空格转大写；不在 `P0/P1/P2` 内一律降为 `P2` |
| `intervalMin` | 转 `int`，转不动或负数 → `0`（0 = 每轮到期，调度器按 60 分钟回退） |
| `lastRun` | `DateTime`/`DateTimeOffset` → ISO 8601（`'o'`）；空 → `$null` |
| `threadId` / `fake` | 空 → `$null` / `false` |
| `repoPath`、`description`、`nextStep`、`currentStage`、`achievement` | 空 → `''` |
| 其它字段 | 原样保留（`schemas/item.schema.json` 的 `additionalProperties: true`） |

`schemas/item.schema.json` 的 `required` 是 `id/title/priority/intervalMin`，但归一之后这四个一定齐，
所以契约自测真正会红的是 **`id` 为空**、**`priority` 非法**、**`intervalMin` 非整数**这几类。
适配器自己的必填校验仍要做（例如 `csv-file` 缺 `id/title/priority/interval` 列直接抛错点名缺哪列），
否则脏数据会在下游变成「静默 P2」。

`write-back()` 的入参是**归一后的 item**（含 `currentStage / nextStep / achievement / threadId`），
`id` 用来定位源行。写回策略一律「只写非空字段」，避免把源单元格清空（见 `csv-file` 的 `Save-PatrolItems`）。

---

## 6. 登记：唯一的 provider 列表就是 `adapters/` 目录

没有第二处注册表。代码里所有「列出 provider」的地方都是**扫目录**：

- `adapter-contract-test.ps1`：`Get-ChildItem adapters -Filter *.adapter.json` → 逐个跑，无需改代码；
- `verify-adapter-spec.ps1`：同样扫目录，并先统计一遍 provider 出现次数以判唯一（`E-DUP`）；
- `patrol-loop.ps1`：不列 provider，只读 `$env:PATROL_ADAPTER`，缺省 `local-json`；
- `Get-PatrolAdapterDescriptor`：按 `<provider>.adapter.json` 单点取文件。

所以「登记」= **放一个 `adapters/<name>.adapter.json` 且 `provider` 字段等于文件名**，仅此一步。
唯一性要求是全局的：两个文件都写 `"provider": "csv-file"` → 两个文件都红（`E-DUP` + `E-FILENAME`）。

需要顺手更新的是**人读清单，不是代码**：

- `README.md`「文件」一节里 `adapters/*.adapter.json` 的条目说明；
- `SKILL.md`「Files」一节；
- 若 provider 面发生实质变化（例如新增第五类落地），README「两种落地」这类叙述也要改。

`tests/verify-provider-isolation.ps1` 里写死的 `bitable / tencent-docs / local-json` 是**回归样例**，
不是注册表：它验的是「同名契约函数同进程不串味」。新增 provider 不需要改它；但如果你的模块
在 dot-source 期有副作用（建目录、读环境、打网络），它仍会被这段回归覆盖到——这是好事。

---

## 7. 跑门禁：顺序、期望输出、判红标准

在仓库根执行（全部要求 **pwsh 7**，UTF-8 无 BOM，离线）：

```powershell
pwsh -NoProfile -File tests/verify-adapter-spec.ps1                       # 1) 描述文件静态漂移
pwsh -NoProfile -File scripts/adapter-contract-test.ps1 -Provider <name>  # 2) 自己那家：装配 + list-items + schema + resolve-name
pwsh -NoProfile -File scripts/adapter-contract-test.ps1                   # 3) 全量（含别人，回归）
pwsh -NoProfile -File tests/verify-no-secrets.ps1                         # 4) 密钥卫生
```

1. `verify-adapter-spec.ps1` 逐文件打 `[PASS]/[FAIL]`，末尾 `summary pass=N fail=0 skip=0 warnings=M`，
   然后跑**自带自证**：在 `%TEMP%` 造 1 好 6 坏样本，断言 13 类规则全部会红、
   `summary selftest pass=3 fail=0`、`RESULT: PASS`、`exit 0`。判红标准：`fail>0` 或 `selftest fail>0`。
2. `adapter-contract-test.ps1 -Provider <name>` 打一行 `[PASS] <name>  items=N  module=...`。
   **需凭据的 provider 是 SKIP 不是 FAIL**，但 SKIP 的条件很具体：
   `needsCredentials=true` **且** `configPath` 这个键解析后为空（键名写死在脚本里）。
   如果你的凭据键叫 `token` 而不是 `configPath`，自测**不会** SKIP，会直接实跑并可能 FAIL——此时给它喂
   `-Values` 或环境变量，或者接受「无凭据必红」。
3. 全量跑完 `summary pass=.. skip=.. fail=..`，`fail` 必须为 0（新增 provider 不能把别人跑红）。
4. `verify-no-secrets.ps1` 扫 `git ls-files` 全部受控文件，`summary pass=.. fail=0 hits=0`。
   新模块里不要出现 token 字面量、`Bearer <24+>`、`AKIA…`、`ghp_…`。

**再加一条端到端**（不是门禁，但接完必须自己看一次）：

```powershell
$env:PATROL_ADAPTER = '<name>'
pwsh -NoProfile -File scripts/patrol-loop.ps1 -TasksFile <样本> -StateFile <临时路径> -Once -DryRun
```

期望：`[round] due=<N>/<N>`、每行 `[worker] done ...`、`[done] digest: scripts/downloads/patrol-<ts>.json`；
digest 里 `method` 必须等于 provider 名（取自 `$AdapterName`，不是写死的 `local-json`）。
给 `-StateFile` 指到临时路径，是为了拿到 `due=N/N` 的干净首轮；用仓内 state 会因上一轮 `lastRun` 变成 `due=0`。
`-DryRun` 只读源（写回走 `Save-PatrolState` 到 state 文件），所以跑完 `git status` 里源码仍应干净。

---

## 8. 常见失败信息 → 对应哪一处写错

### 8.1 `verify-adapter-spec.ps1`（静态，`E-*` / `W-*` / `S-*`）

| 报错 | 写错的地方 | 改法 |
|---|---|---|
| `E-JSON JSON 解析失败` | 描述文件语法 | 逗号/引号；`ConvertFrom-Json` 不容忍注释与尾逗号 |
| `E-REQ 缺必需键 'writeBack'（规格 §10）` | 键名拼错或漏写 | 对照 §2 的 11 个键 |
| `E-TYPE 键 'needsCredentials' 类型不符（期望 bool，实得 string）` | 写了 `"false"` | JSON 布尔不带引号 |
| `E-TYPE writeBack.args.Items 必须是字符串` | `args` 里放了数字/对象 | 一律写字符串或 `${...}` |
| `E-UNKNOWN 未知顶层键 'writeback'` | 键名大小写/拼写 | `writeBack`（驼峰）；确需新键先改规格 |
| `E-ENUM kind='weird' 不在允许值 [file|cli|api]` | `kind` 取值 | 三选一 |
| `E-EMPTY provider 为空` / `title 为空` / `module 为空` / `listItems.function 为空` | 空串 | 补齐 |
| `E-FILENAME provider='x' 与文件名 'y.adapter.json' 不一致` | 文件名与 `provider` 不同 | 改一个，让二者相等 |
| `E-DUP provider='x' 在 2 个描述文件里重复` | 复制粘贴没改 `provider` | 一个 provider 一个文件 |
| `E-ABS module 是本机绝对路径` / `module 含 '..'` | 写死 `C:\work\...` | 改成相对仓库根的 `scripts/...` |
| `E-MODULE module 不存在：scripts/x.ps1（解析为 ...）` | 路径错/文件没建 | 看「解析为」那一行 |
| `E-MODULE module 无法 dot-source：（...）` | 模块顶层就抛错（读文件、读环境、依赖缺失） | 模块顶层只定义函数，动作留到被调用时 |
| `E-SYNTAX 模块语法错误 scripts/x.ps1:12 ...` | 模块语法 | 按行号修 |
| `E-FUNC 函数 'X' 在模块里不存在（dot-source 后未定义；引用它的槽：writeBack）` | 函数名不一致，或函数定义在 `if` 分支里 | 顶层 `function X {}`；名字与描述文件逐字一致 |
| `E-PLACEHOLDER ... 的占位 ${x} 在 config 里找不到（config 可用键：...）` | `args` 里的占位与 `config` 键不符 | 补 `config.x` 或改用 `${tasksFile}` |
| `E-PLACEHOLDER ... 的占位未闭合` | `${x` | 补 `}` |
| `E-OPTIONAL optional 必须是对象` / `optional.syncBack 必须是对象 { function, args }` | 写成了 `[]` 或字符串 | `{}` 或 `{ "function": "...", "args": {} }` |
| `W-DESC description 为空` | 没写说明 | 一句话 |
| `W-MODULE module 不是 .ps1` | 模块后缀 | 用 `.ps1` |
| `W-CONFIG config.x 看起来是本机绝对路径` | 默认值写死盘符 | 改相对路径或空串 |
| `W-OPTIONAL 缺 optional 键` | 漏了 | 写 `"optional": {}` |
| `S-ENCODING ... 5.1 按 ANSI 解码` / `S-PSVERSION ... #requires -Version` | 用 Windows PowerShell 5.1 跑的 | 换 pwsh 7，不要为此加 BOM |

`S-*` 是 skip，不计 FAIL；但只要出现，说明你用的不是 pwsh 7，结论不可信。

### 8.2 `adapter-contract-test.ps1`（实跑，装配/契约）

| 报错 | 写错的地方 | 改法 |
|---|---|---|
| `描述文件 provider='x' 与文件名 'y.adapter.json' 不一致（装配按文件名找模块）` | 同 `E-FILENAME` | 同上 |
| `描述文件缺 module 字段（找不到适配器模块）` | 漏 `module` | 补 |
| `适配器模块不存在：scripts/x.ps1（解析为 ...）` | 路径错 | 同上 |
| `描述文件缺 listItems.function（契约函数必须点名）` | 槽里没写 `function` | 补函数名 |
| `模块 scripts/x.ps1 未定义 listItems.function 'F'（契约不满足）` | 函数名不一致 | 同上 `E-FUNC` |
| `模块 scripts/x.ps1 未定义 optional.syncBack 声明的函数 'F'（到了该能力才炸的坑，这里提前报）` | 能力函数漏实现 | 实现它，或删掉该槽 |
| `Get-PatrolProviderItems: provider=x 必填参数 'ConfigPath' 为空（描述文件声明为必填）` | 占位展开成空串（`config` 默认空且没注入） | 给默认值，或 `-Values`/环境变量注入 |
| `找不到与参数名称 'CsvPath' 匹配的参数。` | `args` 键名 ≠ 模块参数名（高级函数才会报） | 逐字对齐 |
| `list-items() 返回 0 行` | 源为空，或过滤条件把行全筛掉 | 换样本；空源要显式 `return @()` 而不是抛错（空源算 FAIL 是刻意的） |
| `item 'x': 缺必填字段 'priority'` / `字段 'priority' 取值 'P3' 不在 enum` | 归一后仍非法（适配器吐了奇怪的值） | 让归一兜住，或修源数据 |
| `resolve-name() 返回空` | `Resolve-ItemName` 没返回值 | `return $Item.title`（空则回退 `id`） |
| `provider 'x'：adapters/ 下没有对应描述文件（已知 provider：...）` | `-Provider` 打错 | 看括号里的已知列表；`-Provider` 先精确匹配文件名，再退回前缀匹配 |
| `[SKIP] ... 需凭据/配置（configPath 未给）` | 正常，不是错 | 要实跑就给 `configPath`（键名固定） |

### 8.3 运行期（`patrol-loop.ps1` 一轮）

| 症状 | 原因 |
|---|---|
| `Get-PatrolAdapterDescriptor: adapter descriptor not found: ...adapters\x.adapter.json` | `PATROL_ADAPTER=x` 但描述文件不存在 |
| `ConvertTo-PatrolItem: item 缺 id` | `list-items()` 吐了没有 `id` 的行 |
| `[worker] FAIL ... state=Failed` | worker 侧；dry-run 下不该出现（真实模式钩子是 `throw 'real worker not implemented'`） |
| digest `method` 不是你的 provider | 你改的是别的副本，或忘了设 `PATROL_ADAPTER` |
| 第二轮仍 `due=N/N` | 该 provider 不回写源、state 又没落（`-StateFile` 指到临时又被删了） |

---

## 9. 收尾纪律（四条，缺一条就别提 PR）

1. **编码**：新文件一律 UTF-8 **无 BOM**；模块首行 `#requires -Version 7`。仓内所有脚本都是无 BOM 中文，
   5.1 按 ANSI 解码会直接解析失败——这不是兼容性问题，是「只支持 pwsh 7」的声明，别加 BOM 去迁就。
2. **路径**：描述文件里不出现本机绝对路径；`config` 默认值要可移植。
3. **凭据**：不落仓。凭据走环境变量或仓库外密钥文件；`needsCredentials=true`；写回默认关，
   要「配置开 + 显式开」双门（参考 `tencent-docs` 的 `config.syncBack` 与 `-SyncBack`）。
4. **只读**：`list-items()` 不得改源；`write-back()` 只在被调用时写，且只写非空字段。
   Correlator 只读 `git status/log`，不 commit/push。

---

## 附：一页速查

```
adapters/<name>.adapter.json      provider=文件名  module=scripts/<name>-adapter.ps1  kind=file|cli|api
                                  11 键齐 + optional:{}   （未知键=FAIL，缺 optional=WARN）
scripts/<name>-adapter.ps1        Get-PatrolItems / Save-PatrolItems(-Items) / Resolve-ItemName(-Item)
                                  args 键名 == 参数名；${...} 来自 config ← -Values ← PATROL_<PROVIDER>_<KEY>
                                  最少返回 { id, title }；归一与 schema 由装配层兜
登记                              = 放一个描述文件（无第二处注册表）
门禁                              verify-adapter-spec.ps1 fail=0 且 selftest fail=0
                                  adapter-contract-test.ps1 fail=0（凭据家 SKIP 不算红）
                                  verify-no-secrets.ps1 fail=0
端到端                            PATROL_ADAPTER=<name> patrol-loop.ps1 -Once -DryRun → due=N/N，digest.method=<name>
```
