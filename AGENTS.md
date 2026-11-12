# AGENTS.md — patrol-scaffold 交接说明

> 一页读懂本仓：这是什么、怎么跑、改代码的规矩、接口在哪。细节看 `README.md` / `SKILL.md` / `references/` / `docs/`。
>
> **环境**：只支持 PowerShell 7（`pwsh`）。仓内脚本一律 UTF-8 无 BOM，Windows PowerShell 5.1 会按 ANSI 解码而解析失败——判红只认 pwsh 7，不要为迁就 5.1 加 BOM。

## 1. 这是什么

可换数据源的巡检脚手架：同一个调度器驱动飞书多维表格 / 腾讯文档智能表格 / 本地 CSV / 命令输出 / 本地 JSON 五种源，把「周期读一张任务表 → 给每行派一段有界 agent 工作 → 回写结果 → 出摘要」这套 recurring 需求一次实例化，不必每次重造架构。

## 2. 主要思路

- **数据源可换而核心不动**：整条链路只认三个槽位 —— `listItems` / `writeBack` / `resolveName`（对应模块三函数 `Get-PatrolItems` / `Save-PatrolItems` / `Resolve-ItemName`）。换源 = 落 `adapters/<name>.adapter.json` + `scripts/<name>-adapter.ps1` 两个文件；调度器、worker、关联器、输出、看门狗一行不改。
- **调度与格式解析归确定性代码，「下一步做什么」交模型**：到期判定、字段归一、JSON 解析全在代码里；模型只判「本轮做哪一件事」——`prompts/decide-next-action.md` 规定输入与固定三行输出（`动作` / `理由` / `人工介入`），`scripts/decide-next-action.ps1` 只做解析（缺字段、重复字段直接 exit 2，绝不猜），业务判断留给人和模型。
- **无凭据无网络也能自测**：`command` / `csv-file` / `local-json` 三家零凭据零网络实跑；`bitable` / `tencent-docs` 缺凭据时是 SKIP 而非 FAIL。**SKIP = 没实跑，不是没检查**，别当 PASS 读。
- **黄金样本整体脱敏且正向白名单**：bitable 黄金样本逐格替换为虚构形态，正向白名单（`Assert-FakeCellShape`）穷举「只允许虚构形态」，`-CheckOnly` 反向查泄漏；词表列走受控词表且 fail-closed，遇到未知选项直接拒采、不写样本。
- **方向表是只读源，运行态另存**：源里只放「要做什么」；`lastRun` / `currentStage` / `achievement` / `threadId` 落 `state/patrol-state.json`。`list-items()` 不改源，`write-back()` 只写非空字段。

## 3. 关键文件一览

| 路径 | 作用 |
|---|---|
| `SKILL.md` / `README.md` | 入口：七层架构、支持边界、验收线 |
| `VERSION` / `CHANGELOG.md` | 版本唯一事实源 / 变更说明 |
| `schemas/item.schema.json` | item 契约唯一事实源（required: `id`/`title`/`priority`/`intervalMin`） |
| `adapters/*.adapter.json` | 声明式 provider 描述（11 键 + `optional`），provider 名 = 文件名 |
| `scripts/patrol-provider.ps1` | 装配层：读描述、dot-source 模块、归一（`ConvertTo-PatrolItem`）、调三槽位 |
| `scripts/patrol-loop.ps1` | 调度器：due-list、worker 池、回写、digest；换 provider 只靠 `PATROL_ADAPTER` |
| `scripts/patrol-schedule.ps1` | 到期判定（`Get-PatrolDueSelection`）：`intervalMin` 0/空/缺列/负数 = 停跑 |
| `scripts/patrol-state.ps1` | 运行态外置（`state/patrol-state.json`），源保持只读 |
| `scripts/adapter-contract-test.ps1` | 契约自测：装配 → list-items → 每行过 schema → resolve-name |
| `scripts/build-release.ps1` | 可复现打包 + 归档自证（产物落 `%TEMP%`，不入仓） |
| `prompts/decide-next-action.md` + `scripts/decide-next-action.ps1` | 模型决策层：提示词 + 只做解析的脚本 |
| `references/adding-a-provider.md` / `references/adapter-spec.md` | 逐键逐函数操作手册 / 11 节填表模板 |
| `docs/adapting-a-provider.md` | 加源的实测账、8 步清单、常见坑、SKIP 判据（§8） |
| `tests/verify-*.ps1` | 各类门禁（见 §6 命令清单） |

## 4. 常用命令

以下均已在 pwsh 7.6.5 / Windows 上实跑过（括号内是实测输出要点）。

```powershell
# 契约自测：遍历全部 provider（离线）
pwsh -NoProfile -File scripts/adapter-contract-test.ps1
#   → summary pass=3 skip=2 fail=0（command/csv-file/local-json 实跑，bitable/tencent-docs SKIP）

# 描述文件静态漂移闸门（只读、离线，带坏样本自证）
pwsh -NoProfile -File tests/verify-adapter-spec.ps1
#   → summary pass=5 fail=0 skip=0 warnings=0 + summary selftest pass=8 fail=0 + RESULT: PASS

# 停跑语义门禁：intervalMin 0/空/缺列/负数 = 停跑（13 条断言 + 3 个变异自证）
pwsh -NoProfile -File tests/verify-disabled-scheduling.ps1
#   → summary pass=13 fail=0 + summary selftest fail=0 + RESULT: PASS

# 提示词决策层自测：提示词契约 + 解析器行为（不联网、不调模型、零凭据）
pwsh -NoProfile -File tests/verify-decision-prompt.ps1
#   → summary pass=27 fail=0

# 黄金样本脱敏自测：正向白名单 + 反向查泄漏
pwsh -NoProfile -File tests/verify-bitable-golden-sanitizer.ps1
#   → RESULT: PASS

# 跑一轮 dry-run（源只读；运行态落 state/，digest 落 scripts/downloads/）
pwsh -NoProfile -File scripts/patrol-loop.ps1 -TasksFile scripts/sample-tasks.json -Once -DryRun
#   → [round] due=X/Y disabled=Z ... + [done] digest: scripts/downloads/patrol-<ts>.json|.md
#   注意 due 数随工作区 sample-tasks.json 与 state/patrol-state.json 变；
#   要干净的「首轮全到期」信号，把 -StateFile 指到临时路径：
pwsh -NoProfile -File scripts/patrol-loop.ps1 -TasksFile scripts/sample-tasks.json `
  -StateFile (Join-Path $env:TEMP 'patrol-state.json') -Once -DryRun

# 发布打包（产物落 %TEMP%；仓内有未跟踪新文件时必须加 -IncludeUntracked）
pwsh -NoProfile -File scripts/build-release.ps1 -IncludeUntracked
#   → 12 项 verify 全 ok + RESULT: PASS；不带 -IncludeUntracked 且仓内有未跟踪文件时会 FAIL 并列出
```

**中文控制台注意**：本机默认代码页 936 时，`tests/verify-command-adapter.ps1` 与 `tests/verify-item-parity-e2e.ps1` 的中文断言会假红（子进程 stdout 编码）。先 `chcp 65001` 再跑即恢复 `pass=45 fail=0` / `RESULT: PASS`。这是环境问题，不是代码坏了。

## 5. 改动规矩

1. **换 provider 只写两个文件**：`adapters/<name>.adapter.json` + `scripts/<name>-adapter.ps1`，模块实现上述三函数即可。**禁止修改**核心四件 `scripts/patrol-provider.ps1`、`scripts/patrol-loop.ps1`、`scripts/adapter-contract-test.ps1`、`schemas/item.schema.json`；需要动它们说明契约有洞，先补契约。
2. **item 形状以 `schemas/item.schema.json` 为准**，且必须与兄弟仓 `dsh-patrol` 那份逐键一致：`tests/verify-item-contract-parity.ps1`（静态约束面）+ `tests/verify-item-parity-e2e.ps1`（动态解析对拍）两道闸门都要绿。改归一规则（尤其 `priority` / `intervalMin` / `threadId` / `fake`）先跑 e2e。
3. **不引入第二份词表**：`actionType` 的规范取值事实源在 `dsh-patrol` 的 `action-vocabulary.ts`，本仓 schema 里只作文字说明、**不写 enum**。同理受控 select 词表先登记再采，未知取值 fail-closed。
4. **UTF-8 无 BOM**，模块首行 `#requires -Version 7`。
5. **凭据只从环境变量或仓外密钥文件读**（如 `$env:PATROL_BITABLE_BASE_TOKEN`）；仓内任何位置不得出现明文，提交前跑 `tests/verify-no-secrets.ps1`。
6. **不要 git commit / push**：Correlator 只读 `git status/log`；发版、tag、安装都留给发布流程（`docs/releasing.md`）。

## 6. 接口速查

**adapter 描述文件 = 11 必需键 + `optional`**（`tests/verify-adapter-spec.ps1` 的 `$RequiredKeys`）：
`provider`（非空、唯一、等于文件名）、`title`、`module`（相对仓库根、存在、非绝对路径、无 `..`）、`kind`（`file|cli|api`）、`needsCredentials`（bool）、`needsNetwork`（bool）、`description`、`config`（标量）、`listItems` / `writeBack` / `resolveName`（各为 `{ function, args }`），加 `optional`（缺键只 WARN，未知顶层键按 FAIL 处理）。`args` 的键名必须逐字等于该槽位函数在模块 `param(...)` 里声明的具名参数（大小写敏感）；`-Items` / `-Item` 由装配层注入，不许写进 `args`。

**item 契约字段名**：`id`、`title`、`repoPath`、`description`、`nextStep`、`priority`（P0/P1/P2）、`intervalMin`（int，0 = 停跑）、`threadId`、`fake`、`lastRun`（ISO 串）、`currentStage`、`achievement`、`actionType`；`additionalProperties: true`，额外字段原样保留。

**离线自测命令清单**（全部无凭据、无网络，可直接进 CI）：

```powershell
pwsh -NoProfile -File scripts/adapter-contract-test.ps1          # 契约自测
pwsh -NoProfile -File tests/verify-adapter-spec.ps1             # 描述文件漂移
pwsh -NoProfile -File tests/verify-disabled-scheduling.ps1      # 停跑语义
pwsh -NoProfile -File tests/verify-decision-prompt.ps1          # 提示词决策层
pwsh -NoProfile -File tests/verify-bitable-golden-sanitizer.ps1 # 黄金样本脱敏
pwsh -NoProfile -File tests/verify-state-externalization.ps1    # 运行态外置、源只读
pwsh -NoProfile -File tests/verify-provider-isolation.ps1      # 同名函数不串味
pwsh -NoProfile -File tests/verify-csv-file-adapter.ps1        # csv-file 自测
pwsh -NoProfile -File tests/verify-command-adapter.ps1          # command 自测
pwsh -NoProfile -File tests/verify-tencent-docs-adapter.ps1     # 腾讯文档 mock 自测
pwsh -NoProfile -File tests/verify-no-secrets.ps1               # 密钥卫生
pwsh -NoProfile -File tests/verify-item-contract-parity.ps1     # 跨仓静态同源
pwsh -NoProfile -File tests/verify-item-parity-e2e.ps1          # 跨仓动态对拍
```

**面向 agent 的接入入口**：`docs/adapting-a-provider.md` §0.1「面向 Agent 的接入」列出下游 agent 需要知道的全部接口（描述文件 11 键 + 模块三函数 + 跑法 + 离线自测 + 判断下一步做什么的提示词）；速查在 README 的「其他 Agent 快速上手（先跑通命令行再谈架构）」。新增 provider 的逐步操作看 `references/adding-a-provider.md`，业务判断填表看 `references/adapter-spec.md`。
