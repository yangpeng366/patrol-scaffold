# Changelog

本仓发布以 **`VERSION` 文件 + git tag `v<version>`** 标记，没有 `package.json`，也没有构建步骤；
发布物是仓库受控文件的 zip 归档，由 `scripts/build-release.ps1` 生成（见 `docs/releasing.md`）。

格式沿用 Keep a Changelog 的分节（Added / Changed / Fixed / Known limits），日期为 `YYYY-MM-DD`。

## [Unreleased]

主题：**把「两仓解析同一行得到同一份 item」也变成会红的闸门**。上一版只比两份 `item.schema.json` 的
约束面（静态同源），这次补的是动态对拍（同一份行数据喂两边，逐字段相等）。

本轮追加主题：**`巡检间隔 = 0` 从「每轮到期」改为「停跑」**——表数据早就这么用（0 值行普遍写
「停跑 / 停用 / 只读留档」），但调度层仍把 `<=0` 回退成 60，等于每 60 分钟把已停项目唤醒一次。

### Added

- **`tests/verify-bitable-live.ps1`：可选的 bitable 只读实跑闸门（默认离线 SKIP）。** 默认（不带 `-Live`）只跑两条离线自测——分页边界（`next_offset` 缺失时按本页行数推进，推进不了即报错判红，绝不空转）与 `lark-cli` 非零退出透传（mock `exit=23` 与真实 `.cmd` `exit /b 23` 两条）——再对真读打印 `SKIP` 并 `exit 0`，所以 CI 无凭据也不判红。`-Live` 用 `lark-cli base +record-list --as user` 只读方向表：实测 78 行、2 页分页（offset 0,50）、逐行 `Convert-BitableRowToItem` + `ConvertTo-PatrolItem` 归一 78/78，其中在跑 12 行、停跑 66 行（`intervalMin=0` 即停跑）。只读边界：user OAuth 只需 `base:record:read`，只调 `+record-list`，绝不调 `+record-upsert` / `+record-batch-*` / `+record-delete`；写回留待人工批准单独一轮。
- **门禁入口已挂上**：`.github/workflows/verify.yml` 新增 `bitable live gate (default SKIP without credentials)`（走默认路径，不带 `-Live`）；`README.md` 增「Bitable 只读实跑闸门（可选，默认 SKIP）」一节；`docs/adapting-a-provider.md` §8.1、`docs/releasing.md` §1/§5 同步口径；`AGENTS.md` §7.4 补三条实测（真读口径 / 分页不前进判红 / 非零退出透传）与最小权限边界。

- **`tests/record-bitable-golden.ps1`：可重采的脱敏黄金样本。** 用真实 `lark-cli base +record-list --format json` 取表，按固定规则脱敏（列名保留；文本转 `[虚构]`；仓库路径 / GitHub / thread id / 时间改虚构同型值；`rev` 固定 1000），一次采集即确定性输出（同表两次采集哈希相同）。矩阵形状（按列顺序的数组行、select 数组、link 对象数组、null 单元格）正是手写 fixture 盖不住的部分，故由本地对拍脚本直接消费；样本与 `verify-bitable-adapter.ps1` 仍按 `.gitignore` 留在本地，脚本入库，换机可重采。
- **`tests/verify-install-drift.ps1`：安装后 / 升级后的哈希漂移门禁**。此前 skill 同步完只能手工核哈希：
  漏装新文件、拿到旧版内容、编辑器加 BOM、把本地实验脚本一起拷进 skill 目录，都不会有人报错。现在一条
  命令把「已安装 skill 与仓库受控文件一致」变成会红的事实：`-InstalledPath <已安装目录>` 逐文件比 SHA256，
  基准是 **HEAD blob**（`git ls-tree -r HEAD`）而不是工作区字节——`scripts/sample-tasks.json` 的用户未提交
  改动既不算漂移、也不会被读或写；缺文件 / 类型不对 / 内容漂移 / UTF-8 BOM / 不可读 / 多出的受控或源码
  文件全部点名并 `exit 1`（`exit 2` 留给用法错误）。安装目录的运行时产物（`downloads/`、`memory/`、
  `state/`、`reports/`、`*.log`（含 `notify.log`）、`patrol-state.json`、`command-mirror.json`、
  `SHA256SUMS.txt`）不计数也不删除——自检对安装目录只读。参数：`-RepoRoot`（仓路径）、`-InstalledPath`
  （已安装目录）、`-ManifestFile`（完整受控清单，给了一份就覆盖 HEAD 推导）、`-ExcludePath`（通配排除）、
  `-NoSelfTest`。
- **该脚本自带 16 条自证**（%TEMP% 现造真 git 仓 + 6 个受控文件，其中一份模仿 `scripts/sample-tasks.json`）：
  干净副本 PASS、篡改一个字节 FAIL 且点名、缺文件 FAIL 且点名、运行态多余文件不误报且一个没少、多余源码
  文件 FAIL、BOM 报出（`kind=bom`，不是含糊的 content）、工作区脏但安装 == HEAD 仍 PASS（证明以 HEAD 为基
  准）、不可读文件 FAIL 且句柄释放后恢复 PASS、显式清单生效、`-ExcludePath` 生效、CRLF/LF 差异仍判红但
  detail 点明换行符、落后一个提交的旧版副本 FAIL 且点名缺失新文件、新旧两版并存 FAIL 且点名多出的旧受控文件。
  无 `-InstalledPath` 时只跑自证段（CI 跑的就是这个），`summary selftest pass=16 fail=0`。
- **门禁入口已挂上**：`.github/workflows/verify.yml` 新增 `Install drift gate (self-test)`；
  `docs/releasing.md` §1 门禁清单第 10 条 + 新增 §3.1「装完 / 升完必须跑一次安装漂移自检」（含退出码与
  六类 `kind` 的口径）、§4 升级步骤 4b；`README.md` 安装段与文件清单同步。
- **`tests/verify-item-parity-e2e.ps1`**：跨仓端到端对拍。7 条 fixture 行（正常 / 缺 `巡检间隔(分钟)` /
  间隔 `0` / 优先级 `P3` / 假数据 `true` / 字符串 `"true"` / 空白与小数间隔）同时喂本仓
  `BitAbleAdapter.ps1::Convert-BitableRowToItem` 与 dsh-patrol 的 `bitable.ts` + `provider.ts`；逐字段
  （含 null/字符串/数字/布尔的类型）不等即 `exit 1`。兄弟仓或 node 不具备时 `SKIP exit 0`，与
  `verify-item-contract-parity.ps1` 同一口径。自带比较器自证（改坏样本必须红）。
- **`tests/normalize-item-dsh.mjs`**：对拍右侧的读取器。用 Node `--experimental-strip-types` 直接 import
  兄弟仓 TypeScript 原码，只把 `lark-cli` 子进程换成注入的 `exec` 返回 fixture 信封（不联网、不碰真表、
  不装依赖、不手抄 normalize 逻辑）。
- **`tests/verify-disabled-scheduling.ps1`**：停跑语义闸门。9 条 fixture（`intervalMin` = 0 / 缺列 / -15 /
  `null` / 空串 / 90 且刚跑过 / 90 且超期 / 1 且 `lastRun` 空 / 90 且 `lastRun=null`）+ 13 条断言
  （含 due / disabled 集合相等与「due+disabled+pending = 行数」分区完整），直接 dot-source 生产函数
  `scripts/patrol-schedule.ps1::Get-PatrolDueSelection`（不是副本）。自带比较器自证：在 %TEMP% 造 3 个
  变异副本（去掉 `<=0` 跳过 / 恢复旧口径 `<=0 -> 60` / `lastRun` 空时不派发），改坏必须判红并点名到断言。

### Changed

- **调度层改为「`intervalMin` = 0 / 空 / 缺列 / 负数 = 停跑」**（生产口径，表数据约定优先）。
  `scripts/patrol-loop.ps1` 原先把 `<=0` 回退成 60 分钟，已停行会被每轮复活；现在 due-list 交给新文件
  `scripts/patrol-schedule.ps1::Get-PatrolDueSelection`：只有 `intervalMin > 0` 且 `lastRun` 为空 /
  解析不出 / 已超间隔才进 due，停跑行只计数不派发。每轮输出改为
  `[round] due=X/Y disabled=Z maxChildren=... dryRun=...`。worker 池、并发上限、回写与 digest 未动。
- **与 dsh-patrol `src/mapping.ts::itemIsDue`（`<=0 -> 60`）的差异是刻意保留的**：本仓按表数据约定
  优先，兄弟仓一行未改。若要把本仓的表接进 dsh 的 auto 模式，**必须先做映射**（停跑行换标记，或改
  `itemIsDue`），否则已停行会被每 60 分钟唤醒一次。
- `schemas/item.schema.json` 的 `intervalMin` 描述改为「该行最短轮询间隔（分钟）；0 = 停跑（不进入调度）」。
  只改注释面（`type` / `minimum` 未动），跨仓 `verify-item-contract-parity.ps1` 对 dsh-patrol 仍 PASS，
  该差异以 `NOTE` 打印，不误红。
- `tests/verify-state-externalization.ps1`：3 行基线的 `intervalMin` 置为 60。停跑行不派发也就不会回写
  `lastRun`，而该测试验的是「源只读 + 运行态外置」，沿用 0 值会把两件事混在一起；另加一条 `disabled=0` 断言。
- **`scripts/BitAbleAdapter.ps1::Convert-BitableRowToItem` 的归一规则与 dsh-patrol `normalizeItem` 对齐**：
  - `priority`：去首尾空白 + 大写，只有 `P0/P1` 保留，其余（含 `P3`、空）降 `P2`（原实现原样透传，
    `P3` 会破 schema enum）；
  - `intervalMin`：缺列 / 非数字 / `<=0` 一律 `0`，小数向下取整（`45.7 -> 45`，与原 `[int]` 的四舍五入
    `46` 不同）；
  - `threadId`：空串与缺列都是 `null`（原来空串是 `''`，两种形状）；
  - `fake`：只认 Bitable 复选框的真布尔 `true`，字符串 `"true"`/`"1"`/`"yes"` 不再算开；
  - 补 `authorization` / `collaboration` / `approval` / `pendingAction` / `category` 五个字段，缺省值
    与 dsh 同（`自主` / `sparse` / `已通过` / `''` / `''`），映射列 `授权边界` / `协作形态` / `审批状态` /
    `待审行动` / `分类`；
  - `lastRun` / `currentStage` / `achievement` 分别从 `最近执行时间` / `当前阶段` / `外部成就` 取（原来
    恒为 `null` / `''` / `''`）；
  - `id` / `title` / `nextStep` 去首尾空白；`title` 不再回退 `record_id`（空标题由契约层
    `ConvertTo-PatrolItem` 用 id 补齐，解析层与 dsh 同形）。
- `tests/verify-bitable-adapter.ps1` 同步上述口径（`pass=16` → `pass=33`），并补新字段/类型断言。
- `schemas/item.schema.json` **不变**：五个新字段在 `additionalProperties: true` 下合法，且 dsh-patrol 那份
  schema 同样未列它们；只在本仓加会让 `verify-item-contract-parity.ps1` 报 ONLY-LEFT。要进 schema 得两仓同步一次。
- README（新增「巡检间隔：`0` / 空 = 停跑」小节 + 跨仓闸门清单）/ `references/adding-a-provider.md` /
  `references/adapter-spec.md` / `references/patrol-blueprint.md` / `references/csv-file-adapter.md` /
  `docs/releasing.md` / `SKILL.md` / CI 同步新口径与实测数字（3 行样本：`due=1/3 disabled=2`）。

### Fixed

- **`巡检间隔(分钟) = 0` 不再被解析层改写成 60**。原实现 `if ($interval -le 0) { $interval = 60 }` 会让
  行在解析阶段就变成 60 分钟一轮（静默降频），且与 dsh 的 `normalizeItem`（保留 0）不同形。
  现在解析层如实保留 `0`，调度层也不再回退（`0` / 空 / 负数 = 停跑），全链路一个口径。

## [0.2.0] - 2026-11-11

主题：**把「换数据源」从文档承诺变成有闸门的能力**。本版新增契约层、声明式注册、两个离线 provider
（`csv-file` / `command`）与一组机器门禁；`patrol-loop.ps1` / `patrol-provider.ps1` /
`adapter-contract-test.ps1` / `schemas/item.schema.json` 四件核心在本轮 provider 扩展中 **0 行改动**
（口径见 `docs/adapting-a-provider.md` §0）。

### Added

- **适配器契约层**：`schemas/item.schema.json` 作为 item 形状唯一事实源；`adapters/<provider>.adapter.json`
  声明式注册（模块 / 配置 / 三个契约槽位 / `optional` 能力）；`scripts/patrol-provider.ps1` 负责导入、
  归一（`ConvertTo-PatrolItem`）与按 provider 复位函数集合。
- **`scripts/adapter-contract-test.ps1`**：扫 `adapters/` 逐个 provider 实跑装配 → `list-items()` →
  每行过 schema → `resolve-name()`；缺模块/缺函数点名报错，需凭据的 provider 为 SKIP 而非 FAIL。
- **`tests/verify-adapter-spec.ps1`**：描述文件静态漂移闸门（必需键与类型、provider 唯一且与文件名一致、
  `module` 存在、声明函数 dot-source 后存在、`${...}` 可在 `config` 解析、`E-ARGNAME` 校验 `args` 键名
  ⊆ 模块具名参数）；自带坏样本自证（3 好 9 坏，14 类规则必须全红、好样本必须全绿）。
- **provider `csv-file`**：本地 CSV 源，`Import-Csv` 解析、列映射可配、写回只改目标行且保留其余字节，零网络零凭据。
- **provider `command`**：一次命令调用输出 JSON 的源（SCNet / 任意 CLI / 数据库导出）。子进程执行、
  超时杀进程树、退出码透传、stdout 只认 JSON、信封 `itemsPath` 与字段名 `fieldMap` 可配；
  写回只落本地镜像（`state/`，已忽略），源永远只读。随仓分发 mock 命令 fixture，CI 可真跑。
- **provider `tencent-docs`**：腾讯文档智能表格（Smartsheet 记录）适配器，分页 / 按列标题取值 /
  按视图与阶段过滤；写回受 `config.syncBack` 与显式开关双门控制，默认仅落本地镜像。
- **跨仓契约闸门 `tests/verify-item-contract-parity.ps1`**：本仓与 `dsh-patrol` 的 `item.schema.json`
  按约束面逐键比较；CI 稀疏 checkout 兄弟仓后真跑，不再退化成 SKIP。
- **多 provider 隔离回归 `tests/verify-provider-isolation.ps1`**：四家 provider 同进程同名函数互不串味。
- **密钥卫生**：`tests/verify-no-secrets.ps1`（扫 `git ls-files` 全量受控文件，命中即非零退出）、
  `tests/verify-secret-history.ps1`（历史盘点，只报告不改历史）、`.githooks/pre-commit`。
- **运行态外置**：`state/patrol-state.json` 承载 `lastRun` / 阶段等运行态，只读源不再被回写；
  `tests/verify-state-externalization.ps1` 断言源文件字节不变、第二轮 `due=0`。
- **适配文档**：`references/adding-a-provider.md`（逐键逐函数接入清单 + 失败对照表）、
  `docs/adapting-a-provider.md`（command 适配的实测账、8 步清单、何时才该动核心）、
  `references/csv-file-adapter.md`、`docs/tencent-docs-adapter.md`。
- **发布面（本版收口）**：`VERSION`（唯一版本事实源）、本 `CHANGELOG.md`、`docs/releasing.md`
  （门禁 / 打包 / 安装升级 / SKIP 政策）、`scripts/build-release.ps1`（可复现打包 + 归档自证）。

### Changed

- 去掉随仓 vendored 依赖快照，改为 `references/external-dependencies.md` 索引（权威源 / 取法 / 降级底线）。
- CI（`.github/workflows/verify.yml`，windows-latest / `shell: pwsh`）从「跑一个脚本」变成七步：
  描述文件规格漂移、全 provider 契约自测、跨仓 schema 同源、csv-file 离线自测、command 离线自测、
  密钥卫生、发布归档自证（归档写到 `RUNNER_TEMP`，不进工作树）。
- 文档口径与实测对齐：契约自测实测为 `pass=3 skip=2 fail=0`（`command` / `csv-file` / `local-json` 实跑，
  `bitable` / `tencent-docs` 无凭据 SKIP），不再沿用旧的 `pass=2 skip=2`。

### Fixed

- 多 provider 同进程装配时，后装的同名契约函数遮住先装的一家（`Import-PatrolProvider` 改为按 provider
  复位函数集合；老实现必红，回归见 `verify-provider-isolation.ps1`）。
- `pwsh -Command` 只回 0/1，把 CLI 的真实退出码（如 7）压平：`command` 模块改为包一层 scriptblock
  透传 `$LASTEXITCODE`，非 0 一律抛错并回显 stderr 尾部，绝不当空源。
- 巡检运行态写回只读源文件：改落 `state/`，并按 `-StateFile` 隔离（含临时目录自测）。

### Known limits

- `bitable` 与 `tencent-docs` 在无凭据环境是 **SKIP**（`needsCredentials=true` 且 `configPath` 为空）：
  只验到「描述文件 + 模块 + 函数存在 + 装配」，没有实跑真实 `list-items()`。`tencent-docs` 另有本地 mock
  HTTP 服务的离线覆盖（14 条断言）；`bitable` 的读侧也已有离线 harness（`tests/verify-bitable-live.ps1`：
  分页边界 + `lark-cli` 非零退出，6 条断言；真读段默认 SKIP，`-Live` 才实跑），但真实写回仍未被离线覆盖。判定与恢复条件见
  `docs/adapting-a-provider.md` §8。
- 打包脚本在 Windows + PowerShell 7 上验证。zip 字节级可复现仅限同一台机器 / 同一 .NET 版本；
  跨机器请比对 `SHA256SUMS.txt` 的逐文件哈希（`docs/releasing.md` §3）。
- 本版**未**打 tag、未推送：`git tag v0.2.0` 由维护者在验收后手工执行（见 `docs/releasing.md` §6）。

## [0.1.0] - 2026-09-13

初始版本：七层巡检架构（Source Adapter / Scheduler / Worker / Sync-back / Correlator / Output /
Watchdog）+ Trigger 层；`bitable` 与 `local-json` 两个参考落地；`SKILL.md` 入口与 `references/`
蓝皮书；最小可跑 dry-run。无版本文件、无契约闸门、无发布流程（本版起补齐）。
