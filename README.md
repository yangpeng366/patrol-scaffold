# patrol-scaffold

可复用、供应商无关的「定时巡检」自动化脚手架（Codex skill）。

**版本：0.2.0**（2026-11-11）| 变更见 [`CHANGELOG.md`](CHANGELOG.md) | 发布 / 打包 / 安装升级见
[`docs/releasing.md`](docs/releasing.md)；版本事实源是 [`VERSION`](VERSION)。

从一套在用的飞书巡检定时任务系统抽象而来。核心洞察：整套巡检链路里只有最顶层的
「数据源适配器」认识厂商（飞书 Bitable / 腾讯文档智能表格 / Sheets / 本地 JSON），
下面的调度器、worker、关联器、输出、看门狗全部可原样复用。换数据源 = 换一个适配器
+ 改一个 `provider` 配置字段，下游不动。

**适应性的三层落法**（这版起）：契约有 schema 与自测硬约束，装配靠声明式描述文件，
扩展有填表式规格模板。新增一个 provider = 两个文件 + 一次自测 PASS，**主循环不改**。

## 解决什么问题

任何「周期性读一个任务表 → 给每行派发一段有界 agent 工作 → 回写结果 → 摘要入库 →
看门狗自愈」的 recurring 需求，都能用这套蓝图快速实例化，不必每次重造架构。

## 七层架构（只有第 1 层认识厂商）

1. **Source Adapter** — 读行数据为统一 item 结构（可换 provider）
2. **Scheduler** — 按每行 interval + 优先级算 due-list；worker 池并发上限；round 硬超时；全局 mutex
3. **Worker** — 每项一段有界 `codex exec`；按 threadId 续跑否则新建；连续失败 N 次重置
4. **Sync-back** — 回写 CurrentStage / NextStep / Achievement + threadId 到源行
5. **Correlator** — 映射发现 → 本地仓 git 状态
6. **Output** — digest JSON + MD → 记忆库追加
7. **Watchdog** — 独立任务查存活 + 告警，不替主流程做事

外加 **Trigger 层**（计划任务 round 模型 / nssm 常驻）。

## 五种落地（同一 item 契约，换源 = 换 provider）

- **飞书（在用）**：provider=`bitable`，`lark-cli base` 读项目方向表 → 派发 `codex exec` → 回写 Bitable。
- **腾讯文档**：provider=`tencent-docs`，智能表格行 1:1 映射同一 item 契约，下游全不变。
- **本地 CSV**：provider=`csv-file`，零网络零凭据，写回只改目标行。
- **本地 JSON**：provider=`local-json`，dry-run 与教学的默认落地。
- **命令型源**：provider=`command`，一次命令输出 JSON（SCNet / 任意 CLI / 数据库导出）。

各家的当前支持边界（哪家实跑、哪家只是 SKIP、缺口在哪）见下一节，**别把 SKIP 当成 PASS 读**。

## 其他 Agent 快速上手（先跑通命令行再谈架构）

拿到这套 skill 后，**第一步**是 dry-run 验证链路在你的机器上能通（实测为准，无凭据无网络）：

```powershell
cd scripts
pwsh -File adapter-contract-test.ps1      # 契约自测：适配器装配 + 每行过 schema
pwsh -File patrol-loop.ps1 -TasksFile sample-tasks.json -Once -DryRun
```

预期：契约自测 `pass=3 skip=2 fail=0`（`command` / `csv-file` / `local-json` 实跑，
`bitable` / `tencent-docs` 无凭据时为 SKIP 而非 FAIL）；`due=3/3`，三个 worker 完成，
运行态落 `state/patrol-state.json`（**源文件只读，不被回写**），digest 落在
`downloads/patrol-<ts>.json|.md`。立即重跑：`due=0/3`（证 per-row interval 过滤生效）。

> 版本更新后先跑这条链路再谈别的：`due=3/3` 是「装好了」的唯一硬信号。

## Provider 支持边界（0.2.0 实测）

| provider | kind | 凭据 / 网络 | 契约自测 | 本仓离线覆盖 | 写回行为 |
|---|---|---|---|---|---|
| `command` | cli | 无 / 无（mock 命令随仓） | **PASS**（3 行） | `verify-command-adapter.ps1` 45 条断言 | 只写本地镜像 `state/command-mirror.json`，源永远只读 |
| `csv-file` | file | 无 / 无 | **PASS**（3 行） | `verify-csv-file-adapter.ps1` 43 条断言 | 只改目标行的指定列，其余字节保留 |
| `local-json` | file | 无 / 无 | **PASS** | `verify-provider-isolation.ps1` + dry-run | 写回任务 JSON（demo 链路不调用，源只读） |
| `bitable` | cli | 需要（`lark-cli` + config）/ 需要 | **SKIP** | 行映射离线对拍 `tests/verify-item-parity-e2e.ps1`（对兄弟仓 TypeScript 原码，需 node + dsh-patrol 克隆）；`tests/verify-bitable-adapter.ps1` 是本地业务扩展，不入仓 | 受 `sync_back` + 显式 `-SyncBack` 双门控制 |
| `tencent-docs` | api | 需要（开放平台凭据）/ 需要 | **SKIP** | `verify-tencent-docs-adapter.ps1` 本地 mock，14 条断言 | 默认只落镜像；配置 + 显式开关才写远端 |

**SKIP 的判据只有一个**：`needsCredentials=true` 且 `configPath` 展开为空 → 跳过「真实 `list-items()` 实跑」。
在此之前，描述文件解析、模块 dot-source、三个槽位函数与 `optional` 能力函数的存在性都已检查（坏描述文件必红，
不会因凭据 SKIP）。所以 SKIP = **没实跑**，不是**没检查**。

**恢复条件**（不改代码）：把仓外配置文件路径给到 `configPath`，例如
`$env:PATROL_TENCENT_DOCS_CONFIGPATH = "$env:USERPROFILE\.patrol\tencent-docs.json"`，再跑
`pwsh -NoProfile -File scripts/adapter-contract-test.ps1 -Provider tencent-docs`。完整判据、两家的缺口清单、
以及「什么情况下 SKIP 才算阻塞发布」，见 `docs/adapting-a-provider.md` §8 与 `docs/releasing.md` §5。

### 跨仓两道闸门：静态契约面 + 动态解析面

两份 `schemas/item.schema.json` 的对比只能证明「契约文本同源」，证明不了「同一行解析出同一个 item」。
所以跨仓闸门是两条，都要过：

```powershell
pwsh -NoProfile -File tests/verify-item-contract-parity.ps1   # 静态：两份 schema 约束面逐键相同
pwsh -NoProfile -File tests/verify-item-parity-e2e.ps1        # 动态：同一行喂两边，逐字段（含类型）相等
```

`verify-item-parity-e2e.ps1` 的右侧不是手抄的 normalize 副本，而是用 Node（`--experimental-strip-types`，
需 ≥ 22.6）直接 import 兄弟仓 `src/source/bitable.ts` + `src/source/provider.ts`，只把 `lark-cli` 子进程
换成注入的 `exec` 返回 fixture 信封——列映射与归一都是 dsh-patrol 原码。7 条 fixture 覆盖：正常行、
缺 `巡检间隔(分钟)`、间隔 `0`、优先级 `P3`、假数据 true / 字符串 `"true"`、空白+大小写+小数间隔+空串 threadId。
本机没 clone 兄弟仓、或没有 node ≥ 22.6 时打印 `SKIP`（exit 0）并写明缺什么；**SKIP 不是 PASS**。

跑不通先修 pwsh / 路径——链路跑不通之前，架构读了也白读。跑通后再读 `references/patrol-blueprint.md` 理解架构、`references/local-json-adapter.md` 换真实数据源。

## 新增 provider 的验收命令

新增数据源 = 一个描述文件 + 一个模块（业务判断填表见 `references/adapter-spec.md`，逐键逐函数的接入步骤见 `references/adding-a-provider.md`），接完必须过这三条：

```powershell
pwsh -NoProfile -File tests/verify-adapter-spec.ps1                      # 描述文件规格漂移检查（离线、只读）
pwsh -NoProfile -File scripts/adapter-contract-test.ps1                  # 全 provider 契约自测（自动遍历全部 adapter）
pwsh -NoProfile -File scripts/adapter-contract-test.ps1 -Provider <name> # 只验自己那一家
```

`verify-adapter-spec.ps1` 扫 `adapters/*.adapter.json`，逐项校验：必需键齐全且类型正确、provider 唯一且与文件名一致、
`module` 是相对路径且文件存在、`kind` 在允许值内、每个声明的函数 dot-source 后确实存在（只读，不跑写回）、
args 里的 `${...}` 占位能在 `config` 中解析（`${tasksFile}` 例外，由装配层统一注入）、
**每个槽位 `args` 的键名必须是该槽位 `function` 在模块 `param(...)` 里真实声明的具名参数**
（`E-ARGNAME`，逐字比较、大小写也算不同；只查 `args` 键 ⊆ 参数，`-Items`/`-Item` 由装配层注入所以不要求出现在 `args` 里）、
`optional` 必须是对象。
**未知顶层键按 FAIL 处理、不忽略**（拼错成 `writeback` 会被装配层静默取默认值）；缺 `optional` 键只 WARN。
失败 `exit 1`，并自带一段坏样本自证（在 %TEMP% 造 3 条好样本 + 9 条坏样本，断言 14 类规则都会红、好样本仍是绿的，不污染仓库；
其中 `args` 键名闸门是 3 负 2 正：拼错 / 大小写不符 / 函数不存在各一条，部分参数与无参数各一条正例）。

`adapter-contract-test.ps1` 遍历全部描述文件，逐个 provider 打 `[PASS]/[SKIP]/[FAIL]`；缺模块、缺函数会点名报错
（包括 `optional` 里的能力型函数），不会静默跳过；需凭据的 provider 仍是 SKIP 而非 FAIL。
验收线：`verify-adapter-spec.ps1` 为 `fail=0`（且 `selftest fail=0`），`adapter-contract-test.ps1` 为 `fail=0`。

**运行环境**：`verify-adapter-spec.ps1` 与 `adapter-contract-test.ps1` 都要求 PowerShell 7（pwsh）。
两个脚本都是 UTF-8 无 BOM，Windows PowerShell 5.1 会把中文按 ANSI 解码而解析失败。

## 安装、升级与打包

```powershell
# 新装：从发布归档（或 skill-installer / 直接拷目录，三种等价）
Expand-Archive -LiteralPath patrol-scaffold-0.2.0.zip -DestinationPath $env:TEMP\rel
Copy-Item -Recurse -Force $env:TEMP\rel\patrol-scaffold-0.2.0 "$env:CODEX_HOME\skills\patrol-scaffold"

# 升级：停触发器 -> 备份 state/patrol-state.json -> 只换代码文件 -> 跑 dry-run
#       state/ downloads/ reports/ memory/ 与仓外配置不属于发布物，不要覆盖

# 打包（产物落 %TEMP%，不入仓；脚本自带归档自证）
pwsh -NoProfile -File scripts/build-release.ps1 -IncludeUntracked
```

安装后，任何会话遇到 recurring 巡检需求时调用 `patrol-scaffold` skill 即可拿到蓝图。
完整流程（八道本地门禁的期望输出、归档校验清单、可复现口径、升级与回滚）见 `docs/releasing.md`。
发布物结构、`SHA256SUMS.txt` 的用法与 tag 约定也在那一页。

## 文件

- `VERSION` — 版本唯一事实源（`0.2.0`，无 `v` 前缀；tag 才带 `v`）
- `CHANGELOG.md` — 变更说明（Added / Changed / Fixed / Known limits，按版本分节）
- `docs/releasing.md` — 发布手册：八道本地门禁与期望输出、打包与归档校验、安装 / 升级 / 回滚、SKIP 政策
- `scripts/build-release.ps1` — 可复现打包 + 归档自证（清单 / 逐条哈希 / 禁入模式 / HEAD-blob 排除用户改动 / 产物密钥扫描）
- `SKILL.md` — 入口（七层架构 + 适配器契约 + 安全边界）
- `references/adapter-spec.md` — **加一个数据源的填表式模板（11 节）**
- `references/patrol-blueprint.md` — 全架构 + 真实参数 + 两种落地 + 13 步迁移清单 + 踩坑
- `schemas/item.schema.json` — item 契约唯一事实源
- `adapters/*.adapter.json` — provider 声明式描述（模块 / 配置 / 契约函数）
- `adapters/tencent-docs.adapter.json` + `scripts/tencent-docs-adapter.ps1` — 腾讯文档智能表格（第二类真实适配器）
- `adapters/csv-file.adapter.json` + `scripts/csv-file-adapter.ps1` — 本地 CSV 文件（第三类适配器，零网络零凭据；`Import-Csv` 解析、列映射可配、写回只改目标行）
- `adapters/command.adapter.json` + `scripts/command-adapter.ps1` — 命令型源（第四类适配器：一次命令调用输出 JSON，覆盖 SCNet / 任意 CLI / 数据库导出；子进程执行 + 超时 + 退出码透传 + 信封/字段名可配；零凭据，mock 命令随仓分发所以 CI 可真跑）
- `scripts/patrol-provider.ps1` — 适配器装配层（导入、归一、调用）
- `scripts/adapter-contract-test.ps1` — 适配器契约自测（遍历全部 provider；离线校验器）
- `tests/verify-item-contract-parity.ps1` — 跨仓静态闸门：两份 `schemas/item.schema.json` 按约束面逐键比较（带坏样本自证）
- `tests/verify-item-parity-e2e.ps1` + `tests/normalize-item-dsh.mjs` — 跨仓动态闸门：同一份 fixture 行同时喂本仓 `Convert-BitableRowToItem` 与兄弟仓 `bitable.ts`+`normalizeItem`（node 直跑 TS 原码），逐字段比到类型，不等即 exit 1
- `tests/verify-adapter-spec.ps1` — 描述文件规格漂移检查（必需键/类型、provider 唯一、module 存在、声明函数存在、`${占位}` 可解析；带坏样本自证）
- `tests/verify-tencent-docs-adapter.ps1` — tencent-docs 端到端自测（本地 mock 服务，无需真凭据）
- `tests/verify-csv-file-adapter.ps1` — csv-file 离线自测（%TEMP% 沙箱：列映射 / 引号逗号换行 / 缺列报错 / 写回字节保真 / 无 BOM）
- `tests/verify-command-adapter.ps1` — command 离线自测（%TEMP% 沙箱：mock 命令 / 信封与 itemsPath / 退出码 7 / 超时 / banner / fieldMap 拼错 / 镜像幂等 / 与 local-json 的 item 形状一致）
- `docs/adapting-a-provider.md` — **加一个数据源要动多少东西**：本次 command 适配的实测账（核心 0 行）、8 步最小清单、常见坑、何时只加 adapter / 何时动核心、**§8 支持边界与 SKIP 判据**
- `docs/tencent-docs-adapter.md` — tencent-docs 的 11 节适配器规格与落地待办
- `references/csv-file-adapter.md` — csv-file 的 11 节适配器规格 + 「这类源什么时候该用 / 不该用」
- `references/external-dependencies.md` — 外部依赖索引（权威源 / 取法 / 降级），**不随仓分发**
- `references/scheduled-task-recipe.md` — 触发器层注册 recipe
- `tests/verify-no-secrets.ps1` — 密钥卫生门禁：扫全部受控文件，命中即非零退出
- `tests/verify-provider-isolation.ps1` — 多 provider 同进程同名函数不串味（装配层回归）
- `tests/verify-secret-history.ps1` — 历史密钥盘点：只报告命中提交，不改历史
- `.githooks/pre-commit` — 把门禁挂到提交前：`git config core.hooksPath .githooks`
- `.github/workflows/verify.yml` — CI（windows-latest / shell: pwsh）：描述文件规格漂移 + 全 provider 契约自测 + 跨仓 item 契约同源（静态 schema + 动态解析对拍）+ csv-file 离线自测 + command 离线自测 + 密钥卫生 + 发布归档自证（归档落 `RUNNER_TEMP`，不进工作树）

## License

MIT — 见 [LICENSE](LICENSE)。

---

> 注：本仓**不含任何外部依赖副本**。规约、helper 一律读活文件或由 agent 自行下载，
> 取法见 `references/external-dependencies.md`；取不到时按该页「最小纪律」办。
