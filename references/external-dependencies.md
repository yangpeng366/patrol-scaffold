# 外部依赖索引（不随本仓分发）

> 本仓**不含**任何外部依赖的副本。依赖一律只记「权威源在哪、怎么取、取不到怎么办」，
> 由使用它的 agent 自行读取或下载。理由：快照会过期、会带上别人的本机路径与私人笔记，
> 且多数依赖都有更近的权威源（活文件 / 上游仓）。

## 依赖清单

| 依赖 | 性质 | 权威源 | 怎么取 | 取不到怎么办 |
|---|---|---|---|---|
| Codex 全局规约 `AGENTS.md` | 运行时规约 | `$CODEX_HOME/AGENTS.md`（本机 `E:\AI-Portable\codex-home\AGENTS.md`） | 直接读活文件，**以活文件为准** | 按本页「最小纪律」一条条自己遵守 |
| `TextFile.ps1`（写盘/通知 helper） | 兄弟仓的 helper | auto-deploy 仓 `_lib/TextFile.ps1`（本机 `D:\gitAll\auto-deploy\_lib\TextFile.ps1`）；另有同名 skill `auto-deploy-helpers` | dot-source 该文件；或从该仓取一份 | 用退化写法：`[System.IO.File]::WriteAllText($p, $c, [System.Text.UTF8Encoding]::new($false))`（仓内 `scripts/local-json-adapter.ps1` 即此写法） |
| `lark-base-helpers.ps1`（bitable 适配器用） | 兄弟仓的 helper | auto-deploy 仓 `_inter-agent/lark-base-helpers.ps1`（本机 `D:\gitAll\auto-deploy\_inter-agent\lark-base-helpers.ps1`） | 设环境变量 `PATROL_BITABLE_HELPERS_PATH` 指过去 | bitable provider 视为未装 → 契约自测记 SKIP，其余 provider 不受影响 |
| `lark-cli`（飞书 CLI） | 外部工具 | PATH | 见 lark-cli 相关 skill（安装/认证/初始化） | 该 provider 记 SKIP；其余 provider 不受影响 |
| `codex` CLI（worker 执行体） | 外部工具 | PATH | 正常安装 | 脚手架仍可 `-DryRun` 跑通全链路 |

**取依赖的两条规矩**

1. **活文件优先**：凡有活文件（AGENTS.md、helper 源码），一律读活文件，不读任何转抄件。
2. **不落仓**：取下来的依赖放仓外（工具目录、`$env:TEMP`、各自仓），只把「路径/取法」写进
   本页；`PATROL_*` 类环境变量是推荐的传递方式。

## 最小纪律（无外部依赖时仍须遵守）

这一段是本仓自带的、不依赖任何外部文件的行为底线，落地即照办：

- **编码**：写任何源码/配置一律 UTF-8 **无 BOM**；写完验前三字节非 `EF BB BF`。
- **壳**：只用 PowerShell（pwsh 7）；禁 bash 语法（`&&`、`||`、`$()`、`2>/dev/null`、`export`、heredoc）。
- **改文件**：优先用 `TextFile.ps1` 的 `Set-TextFile` / `Set-TextFilePatch`；无该 helper 时用
  `[System.IO.File]::WriteAllText(..., [System.Text.UTF8Encoding]::new($false))`。
- **通禀**：成一次禀一次、阻一次禀一次；长文本走 helper 的 `Send-LarkText -TextFilePath`，
  勿把 `@file` 当字面量发出去。
- **安全**：凭据不入仓、不入日志；外部依赖路径走环境变量，不写死绝对路径。
- **失寻**：引用文件/路径找不到时，先查路径与历史，再翻备份目录，最后捞本机会话记录；
  仍未果则记为阻塞并禀知，不臆造。