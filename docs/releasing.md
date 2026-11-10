# 发布与安装（v0.2.0）

> 本仓没有 `package.json`，也没有编译步骤：**发布物 = 仓库受控文件的 zip 归档**。
> 因此发布流程只有三件事：改版本、跑门禁、打包并自证。本文是这条流程的唯一操作手册；
> 变更说明在 [`CHANGELOG.md`](../CHANGELOG.md)，版本事实源是 [`VERSION`](../VERSION)。

---

## 0. 版本从哪来

| 事实源 | 形态 | 谁改 |
|---|---|---|
| `VERSION` | 单行 `0.2.0`（`x.y.z`，无 `v` 前缀） | 发布人，每次发布一处 |
| `CHANGELOG.md` | `## [0.2.0] - 2026-11-11` 一节 | 发布人，与 VERSION 同步 |
| git tag | `v0.2.0`（带 `v`） | **维护者验收后手工打**，脚本不 tag、不 push |

`VERSION` 是唯一事实源：`scripts/build-release.ps1 -Version <x.y.z>` 只做一致性确认，
值不同直接失败——不允许用命令行参数偷偷改版本。

版本语义（本仓按「skill 的能力面」判，不按内部重构判）：

- **major**：契约破坏（item 必填字段、三个槽位语义、描述文件必需键变更）。
- **minor**：新增 provider / 新增能力槽 / 新增门禁（本项目当前阶段的主要节奏）。
- **patch**：文档与实现的一致性修正、门禁误报修复，不动契约与 provider 面。

---

## 1. 发布前门禁（九条，全绿才算候选）

在仓库根执行，全部要求 **PowerShell 7（pwsh）**、离线、不读凭据：

```powershell
pwsh -NoProfile -File tests/verify-adapter-spec.ps1
pwsh -NoProfile -File scripts/adapter-contract-test.ps1
pwsh -NoProfile -File tests/verify-item-contract-parity.ps1
pwsh -NoProfile -File tests/verify-item-parity-e2e.ps1
pwsh -NoProfile -File tests/verify-provider-isolation.ps1
pwsh -NoProfile -File tests/verify-csv-file-adapter.ps1
pwsh -NoProfile -File tests/verify-command-adapter.ps1
```

外加密钥卫生与运行态外置（CI 里跑前者，后者是本机回归）：

```powershell
pwsh -NoProfile -File tests/verify-no-secrets.ps1
pwsh -NoProfile -File tests/verify-state-externalization.ps1
```

### 1.1 期望输出（0.2.0 实测，2026-11-11，pwsh 7.6.5 / windows）

| 命令 | 判定行 | 判红标准 |
|---|---|---|
| `verify-adapter-spec.ps1` | `summary pass=5 fail=0 skip=0 warnings=0` + `summary selftest pass=8 fail=0` + `RESULT: PASS` | `fail>0` 或 `selftest fail>0` |
| `adapter-contract-test.ps1` | `summary pass=3 skip=2 fail=0` | `fail>0` |
| `verify-item-contract-parity.ps1` | `summary pass=1 fail=0 skip=0` + `RESULT: PASS`（无兄弟仓时 `skip=1`，不算红） | `RESULT: FAIL` |
| `verify-item-parity-e2e.ps1` | `summary items=7 fields-per-item=17 diffs=0` + `RESULT: PASS`（无兄弟仓或无 node ≥ 22.6 时 `RESULT: SKIP`，不算红） | `RESULT: FAIL`（任一字段不等 / 右侧解析报错 / selftest 未过） |
| `verify-provider-isolation.ps1` | `summary pass=12 fail=0` | `fail>0` |
| `verify-csv-file-adapter.ps1` | `summary pass=43 fail=0` | `fail>0` |
| `verify-command-adapter.ps1` | `summary pass=45 fail=0` | `fail>0` |
| `verify-no-secrets.ps1` | `summary pass=12 fail=0 skip=0 hits=0` | `fail>0` 或 `hits>0` |
| `verify-state-externalization.ps1` | `state externalization: PASS` | 任意断言 FAIL |

`adapter-contract-test` 的 `pass=3 skip=2` 是本版**正常**结果，不是缺陷：`command` / `csv-file` /
`local-json` 实跑，`bitable` / `tencent-docs` 因无凭据 SKIP。SKIP 的判据、覆盖缺口与否决条件见 §5。

### 1.2 端到端 dry-run（不是门禁，但发布前必须看一眼）

用 HEAD 版本的任务文件副本，避免把运行态写进工作区：

```powershell
$t = Join-Path $env:TEMP ('patrol-release-e2e-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $t -Force | Out-Null
git show HEAD:scripts/sample-tasks.json | Set-Content -LiteralPath (Join-Path $t 'sample-tasks.json') -Encoding utf8NoBOM
pwsh -NoProfile -File scripts/patrol-loop.ps1 -TasksFile (Join-Path $t 'sample-tasks.json') `
  -StateFile (Join-Path $t 'state.json') -Once -DryRun
pwsh -NoProfile -File scripts/patrol-loop.ps1 -TasksFile (Join-Path $t 'sample-tasks.json') `
  -StateFile (Join-Path $t 'state.json') -Once -DryRun
```

期望：首轮 `[round] due=1/3 disabled=2 maxChildren=2 dryRun=True` + 一条 `[worker] done`，次轮 `due=0/3 disabled=2`；
digest 落在 `scripts/downloads/patrol-<ts>.json|.md`（目录已忽略）。
`due=1/3 disabled=2` 只在用 HEAD 版任务文件（3 行，其中 demo-A / demo-C 是 `intervalMin=0` 的停跑行）时成立；
工作区副本若被加过行，行数会不同，不代表失败。

---

## 2. 打包

```powershell
pwsh -NoProfile -File scripts/build-release.ps1 -IncludeUntracked
```

- 默认输出 `%TEMP%\patrol-scaffold-release\patrol-scaffold-<version>.zip`（外加同名 `.sha256` 旁文件）。
  **不要把输出目录指到仓库内**：发布物不入仓（`*.zip` 也已被 `.gitignore` 覆盖）。
- `-IncludeUntracked` 是刻意的安全闸：有未跟踪且未被忽略的文件时脚本默认失败并列出清单，
  防止把本地临时脚本 / 笔记打进去。发布确实带新文件时才加这个开关。
- 发布物结构：

```
patrol-scaffold-0.2.0/
  VERSION  CHANGELOG.md  README.md  SKILL.md  LICENSE
  SHA256SUMS.txt          ← 逐文件 SHA256（跨机器比对用这个）
  adapters/  docs/  references/  schemas/  scripts/  tests/  .github/  .githooks/  .gitignore
```

### 2.1 脚本做的校验（任何一条不过就非零退出）

| 校验 | 内容 |
|---|---|
| `version` / `changelog` | `VERSION` 是 `x.y.z`；`CHANGELOG.md` 里真有 `## [<version>]` |
| `manifest` | `git ls-files` + 新文件；路径必须相对、文件存在且非空 |
| `no-runtime-files` | 清单不得命中 `.git` / `state` / `downloads` / `reports` / `memory` / `*.zip` / `*.log` / `~$*` / `Thumbs.db` 等 |
| `adapter-modules` | 每个 `adapters/*.adapter.json` 声明的 `module` 都在这份清单里（否则装完即坏） |
| `archive-manifest` | 归档条目集合 == 清单 + `SHA256SUMS.txt`，缺失与多出都为 0 |
| `archive-hashes` | 每个条目与暂存区逐字节一致 |
| `archive-paths` | 所有条目都在 `patrol-scaffold-<version>/` 下，无 `..` |
| `archive-version` | 归档内 `VERSION` == 发布版本 |
| `user-changes-out` | `scripts/sample-tasks.json` 的归档字节 == `HEAD` blob（用户未提交改动不进发布物） |
| `artifact-secrets` | 归档解到 `%TEMP%` 后跑仓内 `tests/verify-no-secrets.ps1`，必须 `fail=0 hits=0` |

### 2.2 「可复现」到什么程度

- **同一台机器**、同一 PowerShell 7 / .NET 版本、同一份输入 → 两次构建的 zip SHA256 相同。
  脚本为此固定了条目顺序（路径排序）与条目时间戳（HEAD 提交时间），不写额外扩展字段。
- **跨机器 / 跨 .NET 版本**不承诺 zip 字节相同（Deflate 实现可能不同）。跨机器判定「内容等价」
  请比对 `SHA256SUMS.txt` 的逐文件哈希：

```powershell
# 校验一个已解包的发布物
Get-Content SHA256SUMS.txt | ForEach-Object {
  $h, $p = $_ -split '  ', 2
  $actual = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $h) { "MISMATCH $p" }
}
```

---

## 3. 安装

三种方式，产物都是同一个目录树，没有依赖安装步骤。

```powershell
# 方式一：从发布归档（推荐给外部使用者）
Expand-Archive -LiteralPath patrol-scaffold-0.2.0.zip -DestinationPath $env:TEMP\rel
Copy-Item -Recurse -Force $env:TEMP\rel\patrol-scaffold-0.2.0 "$env:CODEX_HOME\skills\patrol-scaffold"

# 方式二：skill-installer 从本仓安装（推荐给本机开发者）
#   调用 skill-installer skill，传入本 repo 路径

# 方式三：直接拷目录
#   把本目录拷到 $CODEX_HOME/skills/patrol-scaffold/
```

安装后先跑 §1.2 的 dry-run：`due=3/3` 才算装好。跑不通先查 pwsh 7 与路径，不要先读架构。

目录里**没有** `state/`、`downloads/`、`reports/`、`memory/`——它们分别是运行态、产出与记忆库，
首次运行自动创建。这也意味着**升级时不能拿发布包覆盖它们**。

---

## 4. 升级

```powershell
# 1) 先停触发器（计划任务 / nssm 服务），避免升级时正好在跑一轮
Stop-ScheduledTask -TaskName '<patrol 任务名>'        # 或 nssm stop <服务名>

# 2) 备份运行态（只有它能决定「下一轮谁到期」）
Copy-Item <skill-dir>\state\patrol-state.json <备份目录>\patrol-state-<日期>.json

# 3) 用新版本替换代码文件，保留运行态 / 产出 / 记忆库
#    不要整目录覆盖：state/ downloads/ reports/ memory/ 与仓外配置都不属于发布物

# 4) 校验版本与门禁
Get-Content <skill-dir>\VERSION
pwsh -NoProfile -File <skill-dir>\scripts\adapter-contract-test.ps1

# 5) 跑一次 dry-run + 恢复触发器
```

升级时必看的两个点：

- **`state/patrol-state.json` 兼容性**：本版只存 `id` / `lastRun` / 阶段字段，键集合未变即可直接用；
  若某版改了状态文件形状，`CHANGELOG.md` 的 Changed 节会写明迁移方式（本版无需迁移）。
- **描述文件**：`adapters/*.adapter.json` 属于发布物，会被新版覆盖；**你的 provider 扩展要放在仓外**
  或改成自有文件名后重新过 `verify-adapter-spec.ps1`，否则升级即被覆盖。

仓外配置（凭据、列映射、视图/阶段过滤）一律不进发布物：升级不动它们，安装也不生成它们。

---

## 5. SKIP 政策：什么算阻塞发布，什么不算

`bitable` / `tencent-docs` 在无凭据环境长期是 SKIP。**本版结论：SKIP 不阻塞 v0.2.0**，理由与边界如下。

### 5.1 SKIP 到底跳过了什么

`adapter-contract-test.ps1` 的 SKIP 判据写死在代码里：`needsCredentials=true` **且** `configPath`
展开后为空。跳过的是**唯一一步**——真实 `list-items()` 实跑与逐行 schema 校验。
在此之前已经发生、并未跳过的检查：

1. 描述文件解析、`provider` 与文件名一致、`module` 存在（坏描述文件必红，不会因凭据 SKIP）；
2. 模块 dot-source、三个必选槽位函数与 `optional` 能力函数存在；
3. `verify-adapter-spec.ps1` 对同一批文件的静态规格检查（本版 `pass=5 fail=0`）。

即：**SKIP 表示「没实跑」，不表示「没检查」**。

### 5.2 两家的覆盖缺口（写实，不粉饰）

| provider | 无凭据下已验证 | 缺口 | 本仓离线补偿 |
|---|---|---|---|
| `bitable` | 描述文件 + 模块 + 4 个函数存在 + 装配 | 真实 `lark-cli` 调用、字段名映射、分页 | **无**。`tests/verify-bitable-adapter.ps1` 是本地业务扩展，`.gitignore` 已排除，不随包分发 |
| `tencent-docs` | 同上（3 个函数） | 真实鉴权、真实分页边界、列标题与视图名 | 有：`tests/verify-tencent-docs-adapter.ps1` 用本地 mock HTTP 服务覆盖 2 页读取、归档行过滤、字段映射、epoch 转 ISO、镜像写回（14 条断言全绿） |

### 5.3 为什么不为真跑凭据阻塞 v0.2.0

1. **本版没有改动这两家的代码**：0.2.0 的变更是契约层 / 注册 / 新增 `csv-file` 与 `command` / 门禁，
   `scripts/BitAbleAdapter.ps1`、`scripts/tencent-docs-adapter.ps1`、两份描述文件均未改。用未改动的
   代码去要求新增凭据实跑，验证的是环境而不是发布内容。
2. **凭据不能进 CI / 不能进仓**：本仓的安全底线是「密钥只从环境变量或仓外文件读、仓内不得出现明文」
   （`tests/verify-no-secrets.ps1` 是硬门禁）。为一次版本验收引入仓库 secret，等于用发布流程破坏
   自己刚立的安全约束。
3. **阻塞的收益可被离线手段替代**：`tencent-docs` 的真实代码路径已由 mock 服务覆盖；`bitable` 的缺口
   是「无离线 harness」，这是**已知技术债**，与本版发布无关，已记入 CHANGELOG 的 Known limits。

### 5.4 恢复到「实跑」的条件（可执行，不需要改代码）

```powershell
# 仓外配置文件举例：%USERPROFILE%\.patrol\tencent-docs.json（只放定位信息与列映射，不含明文密钥）
$env:PATROL_TENCENT_DOCS_CONFIGPATH = "$env:USERPROFILE\.patrol\tencent-docs.json"
pwsh -NoProfile -File scripts/adapter-contract-test.ps1 -Provider tencent-docs
```

- 键名固定为 `configPath`（装配层按 `<PROVIDER>_<CONFIGKEY>` 大写生成环境变量名）；键不叫
  `configPath` 的 provider 不会被 SKIP，会直接实跑——那时无凭据必红是预期行为。
- 实跑通过后应把该次输出（不含凭据，只保留 `[PASS] ... items=N`）贴进发布记录的「未验证项」留痕。

### 5.5 阻塞判据（给下一次发布用）

出现下列任一情况，SKIP 就变成阻塞，必须先补离线 harness 或做一次受控实跑再发版：

- 本版改动了该 provider 的模块、描述文件或它依赖的装配层/归一函数；
- `verify-adapter-spec.ps1` 对该 provider 出现 `fail` / `S-*`（skip 意味着「连静态都没验完」）；
- 该 provider 是本次发布的**卖点**（例如首版发布某家 provider）。

---

## 6. 打 tag 与发布（维护者手工，脚本不做）

```bash
git tag -a v0.2.0 -m "patrol-scaffold 0.2.0"
git push origin v0.2.0
```

前提：§1 门禁全绿 + §2 归档 `RESULT: PASS` + `git status --short` 只剩**已知**改动
（本轮基线是用户自有的 `M scripts/sample-tasks.json`，不属于发布内容，归档里用的是 HEAD 版本）。

tag 名带 `v`、`VERSION` 不带 `v`，两者只差前缀，不要互相覆盖。

---

## 7. 回滚

发布物是纯文件树，回滚 = 换回上一版目录 + 换回 `state/patrol-state.json` 备份：

1. 停触发器；
2. 用上一版目录覆盖代码文件（保留 `state/`、`downloads/`、`memory/`）；
3. 恢复 `patrol-state.json` 备份（本版状态形状与 0.1.0 兼容，反之亦然）；
4. `pwsh -NoProfile -File scripts/patrol-loop.ps1 -TasksFile <样本> -Once -DryRun` 看 `due=N/N`；
5. 恢复触发器。

无需数据库迁移、无需卸载依赖——这是「无构建发布」的代价与好处。
