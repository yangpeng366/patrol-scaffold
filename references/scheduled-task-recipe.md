# 触发器层 recipe（怎么把巡检跑起来）

蓝皮书里的 Trigger 层：把"调度器 round"按间隔重复点起来。三种模型，按需选。

## 三种触发模型

| 模型 | 适合 | 语义 |
|---|---|---|
| 计划任务 `-Once` + IgnoreNew | 周期 round 巡检（首选） | 每隔 N 触发一次，脚本跑一轮即退；新触发若旧轮未完则跳过 |
| Register-ScheduledTask（原生） | 同上，PowerShell 可读性好 | 同 schtasks，但用 PS 对象配置 |
| nssm 常驻服务 | 单进程长循环 | 一个常驻进程内自己 sleep+loop；崩溃 nssm 自重启 |

**首选计划任务 round 模型**：round 短、可被 mutex+IgnoreNew 防并发、日志按轮分片、
崩溃后下一触发自动续命。nssm 仅当需要"一个常驻进程持续消费事件流"时才用。

## 关键不变量（三条缺一不可）

1. **Interactive logon，非 SYSTEM**：lark-cli user OAuth token、Edge profile、
   Obsidian 路径都在用户会话里；用 SYSTEM 跑会读不到凭据/profile。计划任务
   `Logon Mode = Interactive only`（见下）。
2. **IgnoreNew / 互斥**：新触发到来若旧轮仍在跑则跳过，叠加脚本内全局 mutex
   `Global\<patrol-name>` 双保险。
3. **round 硬超时 < 触发间隔**：`RoundTimeoutSec` 必须小于触发间隔，否则卡死轮
   会霸占下一触发。脚本内 `RoundTimeoutSec` 兜底强退，让出下次机会。

## 注册一个新巡检（Register-ScheduledTask 模板）

```powershell
$Action    = New-ScheduledTaskAction -Execute 'C:\Program Files\PowerShell\7\pwsh.exe' `
            -Argument '-NoProfile -File "D:\path\Start-MyPatrolLoop.ps1" -Once'
$Trigger   = New-ScheduledTaskTrigger -Daily -At '08:00' `
            -Once:(-not $true)   # 再用 Repetition 加周期
$Reptr     = New-TimeSpan -Minutes 20
$Dur       = New-TimeSpan -Hours 24
$Trigger.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' `
            -RepetitionInterval $Reptr -RepetitionDuration $Dur).Repetition
$Settings  = New-ScheduledTaskSettingsSet `
            -MultipleInstances IgnoreNew `
            -StartWhenAvailable -DontStopOnIdleEnd `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME `
            -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'my-patrol' `
            -Action $Action -Trigger $Trigger -Settings $Settings `
            -Principal $Principal -Force
```

要点：`-MultipleInstances IgnoreNew`、`-LogonType Interactive`、
`-ExecutionTimeLimit` 略大于 round 超时（兜底）。

## schtasks.exe 一行式（快速起一个）

```powershell
schtasks /Create /TN 'my-patrol' /TR 'pwsh -NoProfile -File D:\path\Loop.ps1 -Once' `
  /SC MINUTE /MO 20 /RL LIMITED /F
# 改间隔:  /SC HOURLY /MO 1   ;   /SC DAILY /ST 08:00
```

`schtasks /Query /TN my-patrol /V /FO LIST` 查；`/Change` 改；`/Delete` 删。

## 看门狗（同模型，独立任务）

另起一个计划任务（如 `patrol-watchdog`，每 ~30 min 跑 `Mutual-Watchdog.ps1 -Once`），
只做存活检查 + 告警，**绝不替主流程做事**：查 `runtime.log` 新鲜度
（`MaxIdleMinutes` 超阈值告警）、计划任务是否被 Disabled、codex/worker 进程数。

## 真实实例（当前飞书巡检系统）

| 计划任务 | 动作 | 触发 |
|---|---|---|
| `CodexPatrolCodexAuto` | `pwsh -NoProfile -File Start-CodexAutoPatrolLoop.ps1 -Once` | daily + 周期 |
| `feishu-doc-patrol` | `pwsh -NoProfile -File Start-FeishuDocPatrolLoop.ps1` | daily |
| `feishu-projects-patrol` | `pwsh -NoProfile -File Start-FeishuProjectsWorkLoop.ps1` | daily 02:00 |
| `patrol-watchdog` | `pwsh -NoProfile -File Mutual-Watchdog.ps1 -Once` | 每 ~30 min |

均为 `Logon Mode = Interactive only`，`Status = Ready`（Disabled 的为暂停项）。

## 踩坑

- **SYSTEM 账户跑** → lark-cli user token 401、Edge profile 找不到 → 必须 Interactive。
- **不用 IgnoreNew** → 上一轮卡住时下一触发并发，mutex 抢不到退不干净 → 叠加
  脚本内 `Global\` mutex 双保险。
- **round 超时 ≥ 触发间隔** → 卡死轮霸占调度，永不续命 → `RoundTimeoutSec` 兜底。
- **日志不轮转** → `runtime.log` 涨到 GB 级 → 看门狗查新鲜度前先按大小轮转/截断。
- **nssm 服务 + 计划任务混用同脚本** → 两路触发打架 → 二选一，或服务里跑长循环、
  计划任务只跑看门狗。