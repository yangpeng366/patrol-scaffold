<!-- 参考资料快照（2026-09-12 抄录） -->
<!-- 活文件为准：E:\AI-Portable\codex-home\AGENTS.md（权威源，落地前请重读活文件） -->
<!-- 本件为离线学习/巡检脚手架上下文而抄；规约有重大变更时需同步。 -->
# Codex 全局规约

## 一、编码

凡源码（.java / .py / .c / .xml / .json / .yml 等），必书以 **UTF-8 无 BOM**。

BOM（`\ufeff`）居首，Java 编译报 `illegal character: '\ufeff'`，IDE 视之无形，Linux 构建必坏。

### 治标

```powershell
& "D:\gitAll\auto-deploy\remove-bom.ps1" -Path <path> -Extensions .java -Recurse -Fix
```

例：修某目录下所有 .java：

```powershell
& "D:\gitAll\auto-deploy\remove-bom.ps1" -Path "D:\gitAll\sns-cce2\channels" -Extensions .java -Recurse -Fix
```

### 防患

- Python：`open(path, 'w', encoding='utf-8')`，**非** `utf-8-sig`。
- PowerShell `Out-File`：5.1 之 `-Encoding UTF8` 徒添 BOM，宜用 `[System.IO.File]::WriteAllText()`。
- 写毕必验：前三字节**非** `EF BB BF`。

## 二、壳

本机 **Windows + pwsh 7**（`pwsh.exe`，PATH 自解，详见 MEMORY.md）。**禁 Bash / zsh**。

### 禁 Bash 语法

&&、||、`$()`、2>/dev/null、`export`、`source`、`~/.bashrc`、`<<EOF` heredoc 诸般，皆以 pwsh 之对等代之。

### 必守

- 串行用 `;` 或 `-and` / `-or`，**禁** `&&` / `||`。
- 重定向用 `2>` 或 `2>&1`，**禁** `2>/dev/null`。
- 环境变量用 `$env:VAR`，**禁** `$VAR` / `export`。
- 主目录用 `$env:USERPROFILE`，**禁** `~` / `$HOME`。
- 路径分隔 `\` 或 `/` 皆可，惯用 `\`。
- 多行用 here-string `@"..."@` / `@'...'@`，**禁** `<<EOF` heredoc；收尾 `"@` / `'@` 必顶格、前无空白。

### rg

- 复杂正则用单引号：`g 'pattern'`。
- 字面串加 `-F`：`g -F 'literal'`。
- 通配路径不展开，用 `Get-ChildItem -Filter` 递与 rg，或 `g -g '*.java'`。
- 按名索文件：`g --files`；按内容索文件：`g -l 'pattern'`。
- 正则兼含单双引号者：分多次 rg，或用 `--regex` 转义，勿嵌套冲突之引号。

### 多行 Python

- **禁 Bash heredoc**（`cat << 'EOF' | python` 之类）。
- 用 PowerShell here-string：`@" ... "@ | python -`（收尾 `"@` 必顶格、前无空白）。
- 或写临时文件：`[System.IO.File]::WriteAllText("C:\Users\47037\AppData\Local\Temp\script.py", ...)` 再 `python C:\...\script.py`。
- `python -c "..."` 含中文者一律改写临时 `.py` 文件再调，**禁**直传。

### 管道

`foreach { } | ...` 与 `if { } | ...` **不通**输出，必以 `$()` / `@()` 包之，或先存变量。

## 三、shell 禁则

| 禁 | 代 |
|---|---|
| `<<EOF` heredoc | here-string `@'...'@`（不展开） / `@"..."@`（展开） |
| `cmd1 && cmd2` | `; if ($?) { cmd2 }` 或分两令 |
| `$VAR` 单行 | `"$VAR"` |
| 反引号 `` `n `` `` `t `` | here-string 直书换行 / 制表 |
| `2>/dev/null` | `2> $null` |
| `~/.x` | `$env:USERPROFILE\.x` |
| `export VAR=x` | `$env:VAR = 'x'` |
| `python -c "..."` 含中文 | 写临时 `.py` 文件再调 |

## 四、改文件

helper 优先（已封装于 `D:\gitAll\auto-deploy\_lib\TextFile.ps1`）：

```powershell
. "D:\gitAll\auto-deploy\_lib\TextFile.ps1"
Set-TextFile         -LiteralPath $p -Content $c           # 无 BOM UTF-8 覆盖
Add-TextFile         -LiteralPath $p -Line $l             # 追加一行
Set-TextFilePatch    -LiteralPath $p -OldText $o -NewText $n  # 原地替换
Get-TextFile         -LiteralPath $p                      # 读，自动剥 BOM
```

退化（PS 5.1 / 7.5 通）：

```powershell
[System.IO.File]::WriteAllText($p, $c, [System.Text.UTF8Encoding]::new($false))
```

`Start-CodexAutoPatrol.ps1` 入口已自动 `Invoke-TextFileBomSweep -Fix`。

## 五、禀报

毕工、阻工，皆以机器人飞书通禀。**成则一禀，阻则一禀，余者不禀。**

收件人：`open_id ou_e0744e2b34ff7dee9702e93246ddb775`

```powershell
lark-cli im +messages-send --as bot --user-id ou_e0744e2b34ff7dee9702e93246ddb775 --text "<事>"
```

> **注意**：`lark-cli im +messages-send` 的 `--text/--markdown` 不支持 `@file` 读取；长文本/含特殊字符的消息务必使用 `Send-LarkText -UserId <ou_xxx> -TextFilePath <path>`（封装于 `D:\gitAll\auto-deploy\_lib\TextFile.ps1`），先 `Get-TextFile` 读入变量再透传，避免把 `@xxx` 当字面文本发送（参见 `E:\AI-Portable\codex-home\sessions\2026\09\08\rollout-2026-09-08T17-52-29-…jsonl` 中 2026-09-09 03:03 那条 `@.lark-msg.txt` 字面消息）。

> **注意**：`lark-cli im +messages-send` 的 `--text/--markdown` 不支持 `@file` 读取；长文本/含特殊字符的消息务必使用 `Send-LarkText -UserId <ou_xxx> -TextFilePath <path>`（封装于 `D:\gitAll\auto-deploy\_lib\TextFile.ps1`），先 `Get-TextFile` 读入变量再透传，避免把 `@xxx` 当字面文本发送。

### 成

改码、构建、部署、多步之工，验定后禀。一行简言：何文件、何果。
先更记录、再发通知；任务库（`STATE.md` / `DECISIONS.md` 等）与通知并行不废。

### 阻

权限、冲突、阻塞难进者，禀，明卡点与所需。简查、闲聊、常流程**不禀**。
语简意明；与完成通知互不相扰：阻则禀操作，成则禀完成。

## 六、质素

- 改毕必测，**实测**为准，勿臆断「应无碍」。
- 以用户视角交付，求直觉、流畅、低认知负担。
- 工程七鉴（契约、证验、简省、文责、双语、思痕、成迹）可按需参 `harness-reminders`。此乃提醒，**非**硬门；用户指令与仓库规约优先。

## 七、思与言

思考与输出，苟可，亦文言；字必简体为先。

## 八、引用

- 部署上下文：`.codex/deployment-context.md`（双机拓扑、CCX 路由、网关、挂载）。
- X240 完整配置：`D:\BaiduSyncdisk\Obsidian Vault\当前项目\02_部署运维\X240_辅助机状态与配置.md`。
- Codex 模型目录：`C:\Users\47037\.codex\ccx-model-catalog.json`。

## 九、文档分层

详见 `DOC_GOVERNANCE.md`。本文件仅留全局底线。

- L0：运行源、skills/SKILL.md，不压缩。
- L1：AGENTS.md、DOC_GOVERNANCE.md、deployment-context.md，**仅**重大变更。
- L2：`当前项目/02_项目推进/`，方向与稳定决策。
- L3：MEMORY.md、memory/、运维记录，**三日一整**；空壳、重复、过期者先归档后清。

## 十、飞书 Bitable 留痕

Codex 推数入多维表格，**`lark-cli base +record-batch-create --as user`** 为正途，免 app secret / 协作者 / 租户 token 之烦。

- 禁租户 token 直调 API（屡遇 400/403）。
- 禁 `+app-create`（`app_token` ≠ `base_token`）。
- 单 `--json` 不超 200 条（Win 命令行 32K 上限，BATCH 取 50）。
- 启 user OAuth + 后台勾选 `bitable:app base:record:create` 并发布版本（首次需审批）。
- 典：详见 `E:/AI-Portable/codex-home/skills/linreaf-load-test/references/lark-cli-feishu-bitable.md`。

## 十一、少用截图

图额有限，**少**截图。凡报错、界面、图表，先以文本取之（读文件、日志、命令输出）。必赖目观者，宁飞书请用户代劳，**勿**妄截。

## 十二、文件失寻

凡所引文件、路径、工具而寻不得者，**先**疑其被删或被移。处置次第：

1. 验路径、查拼写，循历史（`git log` / `git blame`）。
2. 翻目录：`02_部署运维/_backup-root-md/`、`.backup-*/` 之类。
3. **未果**，捞 Codex 本机会话：`C:\Users\47037\.codex\sessions\`（按年/月分层）。
   - 按日期筛 `*.jsonl` / `events.jsonl`。
   - 觅彼时 `apply_patch` / `exec_command` 之全文，可复原本意与路径。
4. 仍缺，记任务库为 `blocked` 并注缘由，飞书禀用户。
## 十三、隐（启发）

程中所生之息，用户不须览者：

- 暂存为宜，毋污主仓（$env:TEMP 之类）。
- 或以 base64 蔽之，免屏满。
- 或分块、摘要、延后读取，随宜而择。
- 思亦可隐，善启发、戒冗陈，毋徒耗 token。

此启发之策，非死律；显隐之度，因事而裁。