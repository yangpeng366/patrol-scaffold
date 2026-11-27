# Changelog

本仓发布以 **`VERSION` 文件 + git tag `v<version>`** 标记，没有 `package.json`，也没有构建步骤；
发布物是仓库受控文件的 zip 归档，由 `scripts/build-release.ps1` 生成（见 `docs/releasing.md`）。

格式沿用 Keep a Changelog 的分节（Added / Changed / Fixed / Known limits），日期为 `YYYY-MM-DD`。

## [Unreleased]

主题：**把「两仓解析同一行得到同一份 item」也变成会红的闸门**。上一版只比两份 `item.schema.json` 的
约束面（静态同源），这次补的是动态对拍（同一份行数据喂两边，逐字段相等）。

本轮追加主题：**`巡检间隔 = 0` 从「每轮到期」改为「停跑」**——表数据早就这么用（0 值行普遍写
「停跑 / 停用 / 只读留档」），但调度层仍把 `<=0` 回退成 60，等于每 60 分钟把已停项目唤醒一次。

再追加主题：**两道口径散文闸门的扫描面收口到「受控文件集」**。它们原来按目录递归扫 `docs/` > `references/` >
`adapters/`，于是本机 gitignored 的本地扩展（如 `docs/jev-shadow.md`）也被扫进去：同一提交在本机扫
20/25 份、在 CI 只扫 19/24 份，出现「本机绿 / CI 不可复现」两个口径。现在默认按 `git check-ignore`
排除 gitignored 路径（命中时打 `NOTICE` 点名），扫描面与 CI 字节级同源；本机想连扩展一起看，
显式加 `-IncludeLocalExtensions`（opt-in，不参与 CI 判定）。非 git 副本（已安装 skill 目录）退化为磁盘全量。

### Added

- **`scripts/sync-install.ps1` + `tests/verify-install-sync.ps1`：装/升安装的「按 HEAD 字节同步」。**
  `docs/releasing.md` §4 早就承认升级只能「逐文件用 HEAD 字节覆盖」，但那条路一直是手工的——实际代价
  是一次「补 18 个缺文件、覆盖 48 个漂移文件」的操作，且 `core.autocrlf=true` 下取出来的 CRLF 会一次性
  变成几十条 `content … 仅换行符不同`。本脚本把这一步变成一条幂等命令：基准同样是 HEAD blob（不是工作区），
  只在字节不同/缺失时写，写入用原始 blob 字节（不解码，不会引入 BOM 或改换行符），**只写不删**——运行时产物
  被显式拒写，本地扩展留着让 drift 自检报 `extra`（删不删由人定），受控路径被目录占位则 `exit 1` 点名。
  自带 13 条行为闸门（`summary pass=13 fail=0`）：干净副本 `written=0`、`-DryRun` 不落盘、漂移副本 `written=3`、
  同步后交 `verify-install-drift` 复核只剩 `extra`、运行态字节不变、扩展不删、连跑两次幂等、CRLF 副本同步后
  drift 直接 PASS、目录占位 `exit 1`、三类环境错误 `exit 2`。
- **`tests/verify-gate-claim-counts.ps1`：三道闸门的断言数机器对拍（离线，零凭据零网络）。** 上一轮把
  `pass=20 / pass=38 / pass=19` 校准到实测值，靠的是人工复跑；没有任何东西守「加了一条断言却忘改文档」。
  本轮把它变成闸门：子进程真跑 doc-gate / interval-zero / scan-scope 取 `summary pass=N`（必须 `exit 0` +
  `RESULT: PASS` + `fail=0`），再扫 AGENTS / README / SKILL / docs / references 里给这三道闸门写的断言数
  （`pass=N` 与 `N 条断言` 两种写法），逐个必须等于实测，不等就点名 `file:line` 判红。归属按行/块判：同行
  唯一文件名 / 自描述 `doc-gate=passN` / 结果行（`#   → summary pass=N`）回溯上文命令 / 说明注释前探下文
  命令；未登记闸门的数（如 `verify-csv-file-adapter`）不串味；`CHANGELOG.md` 是发布历史，
  不参与对拍（只 `NOTICE` 点名）。
  自带 6 段成对自证（陈旧数字必红 / 正确必绿 / 结果行归属 / 前导注释归属 / 未登记闸门不串味 / 自描述写法），
  已挂 CI `gate claim-count cross-check`。改坏实测：把 README 的 `38 条断言` 改成 37 → 判红并点名
  `README.md:201 写 N 条断言=37（实测 38）`。本闸门自身不对外公布断言数——否则又是一个没人守的数字。
- **断言数对拍扩到六道闸门：`disabled-scheduling` / `writeback-plan` / `command-adapter` 一并登记。**
  上一轮只守三道具文/扫描面闸门，其余自带数字的离线闸门（停跑语义 13 / 回写层 51 / command 45）仍靠人眼。
  本轮把 `$gates` 表作为唯一登记面：加闸门只加一行，自描述正则（`<key>=passN`）从表里生成，判红点名也用
  表里的短名。两处口径差异如实登记而不是硬编特例：`verify-command-adapter.ps1` 只打
  `summary pass=N fail=0`、不打 `RESULT: PASS`，故其行 `EmitsResult=$false`；归属侧同时收窄到 `verify-*.ps1`
  （同段提一句 `scripts/patrol-writeback.ps1` 不算「第二名」），未登记闸门与「一行两名」一律只打 `NOTICE` 不猜。
  自证从 6 段扩到 9 段（新增：新登记闸门的自描述写法必红 / 一行两名都登记不猜 / 一行两名仅一家登记也不猜）。
- **`scripts/patrol-writeback.ps1`：回写层落地，默认 preview（零远端写入）+ 幂等键 + 可重放账本。**
  此前第 4 层 sync-back 只有两条路：`Sync-BitableRoundResult` 直写（开了门就写，重跑就重写），或者不写。
  现在中间多一层计划：digest 一行翻译成一个字段集 + 一个确定性键
  `sha256("v1|<provider>|<target>|<stamp>|<itemId>|<payloadJson>")`，并落
  `state/writeback-ledger.json`（只追加、只记成功写入）。因此：同一 digest 重放 → `replay` 不写；换 stamp
  但内容未变 → `unchanged` 不写；内容变了 → `apply`。`provider` / `target` 参与键空间，换表不会误判
  「已写」。默认档只打印计划，零网络、零远端写入、账本不建；`-Apply` 是唯一写入口，写字不是自己拼
  `lark-cli`，而是走 provider 的 `optional.syncBack`（bitable 仍受 `config.sync_back` 门约束），或给
  `-WriterScript` 走自定义/离线通道。字段口径 `currentStage` / `achievement` / `nextStep` / `threadId`，
  空值不写；`nextStep` 只在 digest 行真带上时才写（属源表行，本仓 digest 默认不含）。退出码：0 全成、
  1 有行写失败（失败行不入账，可原样重试）、2 用法/环境错误（含账本损坏——刻意 fail-closed，不当空账重来）。
- **`tests/verify-writeback-plan.ps1`：该层的离线门禁（51 条断言，零凭据零网络）。** 覆盖：preview
  逐字节不改 digest/state、不建账本、不调写手；键的确定性（两跑同键）与敏感性（stamp/provider/target/内容
  任一变化必换键，同内容不抖动）；同 digest 重放 `replay=3` 且写手调用 0 次；换 stamp 内容未变
  `unchanged=2` 且一行不写；写手报失败/输出非 JSON/漏报某行 → `exit 1` 且只失败行不入账、重试只补那一行；
  账本损坏或 version 不认识 → `exit 2`；provider 没有 syncBack 能力 → `exit 1` 不假装成功。写手替身在
  `%TEMP%` 现造（`tests/fixtures/` 在 .gitignore 里，不在仓内放替身），CI 同样自包含。

  新增 §9「provider 双门组合」端到端：临时 provider（`%TEMP%` 里只拷被测的三个脚本，哈希断言与本仓
  逐字节相同）把两道门做成四象限，各真跑一次 `-Apply` —— 门 A = 描述文件是否声明 `optional.syncBack`，
  门 B = 配置 `sync_back`。只有 A∧B 才 `exit 0` + 能力槽收到字段 + 账本记 1 条（`writer=provider:wbgate`）；
  A 开 B 关、A 关 B 开、双关三种负例一律 `exit 1`、能力槽零调用、不建账本。provider 通道也验证幂等：
  同一 digest 重放 `replay=1`，不再调能力槽。门禁已挂进
  `.github/workflows/verify.yml`（`writeback plan self-test`）。

- **`tests/verify-doc-gate-claims.ps1`：把「双门散文口径」也变成会红的闸门（19 条断言，零凭据零网络）。**
  上一轮修掉的是幽灵开关本身，挡不住同一个谎再写一遍：描述文件层的键名漂移有 `verify-adapter-spec.ps1` 的
  `E-ARGNAME` 兜着（args 键 ⊆ 函数具名参数），但 README / SKILL / AGENTS / CHANGELOG / references / adapters
  里的散文没人守，别写成「受 `sync_back` + 显式 `-SyncBack` 双门控制」——那样测试仍全绿。现在：①用 PowerShell AST
  钉住 `Sync-BitableRoundResult` 的具名参数必须恰好是 `BitableConfigPath` / `Item` / `Identity`；②按段落/表格行
  扫 20 份文档与描述文件，凡「提 bitable 又提 `-SyncBack` 且无否定词」即判红（表格行各自成段，否定词不外溢；
  明确归给 tencent-docs 的句子不误伤）；③自证不空转——两段历史漂移原文（`45f269d` 的模块头注释与 README 行，
  都不含函数名，正是「只匹配函数名会放过真凶」的证据）必须判红、改正后同一句必须判绿；④拿 tencent-docs 真声明的
  `Save-PatrolItems -SyncBack` 与描述文件 `${syncBack}` 映射做正例，证明规则只咬 bitable。实测把旧文案粘回
  README 末尾 → `fail=1 exit=1`，`git checkout` 还原后 19/19 绿。已挂进 `.github/workflows/verify.yml`
  （`doc gate-claims drift`）与 `AGENTS.md` 离线清单、`SKILL.md` 测试清单。

- **`tests/verify-interval-zero-claims.ps1`：把「`interval=0` = 停跑」的散文口径也变成会红的闸门（37 条断言，零凭据零网络）。**
  `verify-disabled-scheduling.ps1` 只钉运行时行为（喂 fixture 看 due/disabled 落点），挡不住散文把旧口径再写一遍。
  本轮实测就扫出 4 处旧口径真漂移：`references/csv-file-adapter.md` 的触发间隔行仍写着「`interval=0` 回退 60 分钟，
  与骨架一致」，`scripts/sample-tasks.csv` 与 `scripts/sample-tasks.json` 的示例说明把 0 说成每轮都到期，
  `tests/fixtures/command/mock-jobs.ps1` 的 note 同样——读者照着做就是「已停项目每 60 分钟被唤醒一次」。
  本仓口径是「0 / 空 / 缺列 / 负数 = 停跑（disabled），绝不回退默认间隔」，示例数据本身就是反例
  （demo-A / demo-C 是 `due=1/3 disabled=2` 里的停跑行），文案与行为必须同口径。现在：①用 PowerShell AST 钉
  实现事实——`Get-PatrolDueSelection` 必须显式比较 0、把停跑行收进 `disabled`、函数体里没有 `= 60`；
  `Convert-BitableRowToItem` 必须把缺列/非法归 `0`；`patrol-loop.ps1` 必须走同一函数、不自己算间隔；
  ②扫 24 份受控文件（本机另有 1 份 gitignored 的 `docs/jev-shadow.md` 一并扫），双粒度——「提 interval 0 又说
  每轮到期」按句子判（同段落里先描述旧实现、紧接新长出一句旧口径仍判红），「回退 60 / 当最短间隔」按段落/行判
  （`旧实现` / `兄弟仓 dsh-patrol` 标注不误伤，表格相邻行的否定词不外溢）；③自证不空转——5 段旧口径原文
  （逐字取自上述真漂移 + 一句三元兜底）必须判红，5 句改正后文案（含「从每轮到期改为停跑」）必须判绿；
  ④不一刀切——兄弟仓的 `<=0 -> 60` 是刻意保留的差异，讲它的句子必须绿；「`lastRun` 空 = 到期」不是停跑，不许误判。
  实测把旧口径贴回 `docs/releasing.md` → `fail=1 exit=1`，`git checkout` 还原后 37/37 绿。已挂进
  `.github/workflows/verify.yml`（`interval-zero claims drift`）与 `AGENTS.md` / `README.md` / `SKILL.md` 清单。

- **`tests/verify-scan-scope-selfproof.ps1`：给「扫描面收口」补仓内成对自证（19 条断言，%TEMP% 现造 git 仓，零凭据零网络）。**
  上一轮把两道口径闸门的扫描面收口到「受控文件集」，但证据只有本机凑巧存在的那份 `docs/jev-shadow.md`：
  干净机器（CI）上两道闸门都走「无可排除」分支，于是排除逻辑写错的两个方向——排过头、压根没排——都仍然全绿。
  本轮把「排除真生效」本身变成可复现的断言：①按 `git ls-files` 把 64 份受控文件复制进 `%TEMP%` 现造的 git 仓，
  用 `git add -Af` + commit 落地（裸 `add -A` 会漏掉 `tests/fixtures/` 下两份「已跟踪但被 .gitignore 盖住」的文件，
  临时仓受控集就只剩 62 份，闸门的「排除 N 份」随之失真——这条也是本轮跑出来的真发现）；②写一份被
  `.git/info/exclude` 挡住的漂移样本，样本里同时抄着两道闸门各自认得的历史漂移原文（幽灵写回开关一段 +
  `intervalMin` 被回退成默认间隔一段）；
  ③两道闸门各跑三段：A 默认必绿且打出 `NOTICE … 跳过 1 份 … local-extension-sample`，B `-IncludeLocalExtensions`
  必红且点名样本，C 把样本 `git add -f` 提成受控后再默认跑必红、且不再打 NOTICE（反证 A 的绿来自收口，
  而不是扫描器瞎了）。变异实测两个方向：把默认排除改成恒不生效 → A 段红（`FAIL 6) … 泄漏 1 份`）；
  改成连 `docs/` 全排（排过头）→ A 段的 NOTICE 断言与 C 段同时红。已挂进 `.github/workflows/verify.yml`
  （`scan-scope self-proof`）与 `AGENTS.md` 离线清单、`SKILL.md` 测试清单。

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

- **CI 首跑核准 + 三道闸门断言数校准**：`scan-scope self-proof` 在 GitHub Actions 首跑（run 38 / `ec3af79`）
  相关三步全绿——`doc gate-claims drift`（step 17）、`interval-zero claims drift`（step 18）、
  `scan-scope self-proof`（step 19）；本机复跑三条闸门实测 `pass=20 / pass=38 / pass=19`，均 `fail=0`。
  据此把口径数核准到实测值：doc-gate 19→20、interval-zero 37→38，并把三道闸门补进 `README.md` 文件清单
  与 CI 描述行（此前清单只提 interval-zero 一条，doc-gate 与 scan-scope 没有入口，读者找不到怎么跑）。
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

- **安装文档里的 `"$env:CODEX_HOME\skills\patrol-scaffold"` 在未设 `CODEX_HOME` 的机器上是一条假命令。**
  本机实测 `CODEX_HOME` 为空：该写法展开成 `\skills\patrol-scaffold`，自检随即 `RESULT: FAIL — 安装目录不存在
  或不是目录` / `exit 2`——看起来像环境坏了，其实是路径没解析。README、`docs/releasing.md` §1/§3/§3.1/§4
  与 `tests/verify-install-drift.ps1` 的帮助示例统一改成先解析一次
  `$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }` / `$skillDir`，
  并在原处写明「`CODEX_HOME` 未设时默认 `~/.codex`」。脚本行为未变（无参数仍只跑自证段，不自动猜安装目录）。

- **`bitable` 写回的「双门」口径更正：不存在 `-SyncBack` 参数**。`scripts/BitAbleAdapter.ps1` 头注释、
  `adapters/bitable.adapter.json` 的 `description`、`README.md` 的 provider 表格（以及
  `references/adding-a-provider.md` 两处）此前都写「受 `config.sync_back` + 显式 `-SyncBack` 双门控制」，
  但 `Sync-BitableRoundResult` 的真实签名只有 `BitableConfigPath` / `Item` / `Identity`——`-SyncBack`
  从首个提交 `3be8afa` 起就从未存在（`git show 3be8afa:scripts/BitAbleAdapter.ps1` 可核），是文案从
  旧实现带过来的幽灵开关。真实双门按已落地的实现写清：门 A = 描述文件声明 `optional.syncBack`
  （`patrol-provider.ps1` 判，缺槽零调用），门 B = 配置 `sync_back=true`（模块自判）；人工显式触发是
  上游 `patrol-writeback.ps1 -Apply`（默认 preview）。口径同步进 `AGENTS.md` §6、`SKILL.md` Safety、
  `references/adding-a-provider.md` §2/§9，并把 `tencent-docs`（确实有 `-SyncBack` 参数）与 `bitable`
  （没有）两种合法形态分开写明，避免下次再把「显式开」笼统写成 CLI 开关。
  未改代码行为：`tests/verify-writeback-plan.ps1` 的 51 条断言仍全绿，§9 的四象限（能力声明门 × 配置门）
  本来测的就是这两道门。

- **`巡检间隔(分钟) = 0` 不再被解析层改写成 60**。原实现 `if ($interval -le 0) { $interval = 60 }` 会让
  行在解析阶段就变成 60 分钟一轮（静默降频），且与 dsh 的 `normalizeItem`（保留 0）不同形。
  现在解析层如实保留 `0`，调度层也不再回退（`0` / 空 / 负数 = 停跑），全链路一个口径。

- **`verify-install-drift.ps1` 的 `ok=` 不再可能为负**。原实现用 `checked - findings.Count` 算 `ok`，
  而 `extra`（清单外多出的本地扩展）不在 `checked` 里，于是「受控 66 个 + 2 个本地扩展」的真实场景
  会打印 `checked=66 ok=-2 fail=68`——数字自相矛盾，读起来像自检自己算错了。现在 `ok` 的口径是
  「受控文件里没被点名的个数」（新增 `OkFiles` 字段），本机实测同一场景为
  `checked=66 ok=0 fail=68 missing=18 content=48 extra=2`。自证加一条
  `e2) extra 不让 ok 变负`，总数 16 → 17，`README.md` 与 `docs/releasing.md` §3.1 的散文数同步。

- **已安装副本（非 git 仓）里量不了自检，`verify-install-drift.ps1` 直接 `exit 2` 拒跑**。真实的安装目录
  只是一份拷贝、没有 `.git`，于是「只跑自证段」这个最常用的场景（换了台机器、包已装好、仓还没拉）
  拿到的是一句「不是 git 仓库」。现在区分两种情形：不带 `-RepoRoot` 且它**默认解析出来的目录**不是 git 仓
  （典型就是已安装 skill 目录）→ 打 `[NOTICE] 非 git 副本…`、只跑自证段、`RESULT: PASS` 退 0；
  人**显式**传了 `-RepoRoot`/带了 `-InstalledPath` 却指到非 git 仓 → 仍 `exit 2`（避免参数用错时默默 PASS）。
  自证加两条（`n` 非 git 副本不 exit 2 / `n2` 显式非 git 仓仍 exit 2），17 → 19 条，README 与 §3.1 散文数同步。
  另：`docs/releasing.md` §4 记下本轮实测的坑——`core.autocrlf=true` 的 Windows 上 `git archive` 取出来是
  CRLF，整包拷进安装目录会让 66 个文件全报「仅换行符不同」，得用
  `git -c core.autocrlf=false -c core.eol=lf archive …` 取 LF 字节。

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
