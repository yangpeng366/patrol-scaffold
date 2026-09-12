# local-json 适配器（provider = local-json）

`local-json` 是最简 provider：数据源是一个本地 JSON 文件，每行一个任务方向。
无需凭据、无需网络，任何机器都能跑——专门用于 dry-run 验证整套七层链路、
以及给新 Agent 一个拷下来就能端到端跑通的最小样例。

## 契约映射

| 蓝皮书方法 | 本适配器实现 |
|---|---|
| `list-items()` | `Get-PatrolItems -TasksFile` 读 JSON → PSCustomObject 数组 |
| `write-back(id, fields)` | 主进程回写 item 字段后 `Save-PatrolItems` 落盘；或 `Set-PatrolItemFields` 单条更新 |
| `resolve-name(id)` | `Resolve-ItemName` 直接取 `title` |

## item 字段

`id / title / repoPath / description / nextStep / priority(P0|P1|P2) /
intervalMin / threadId / fake / lastRun(ISO) / currentStage / achievement`

## 怎么跑

```powershell
cd D:\gitAll\patrol-scaffold\scripts
pwsh -File patrol-loop.ps1 -TasksFile sample-tasks.json -Once -DryRun
```

首轮：3 行全到期（`lastRun=null` 视为到期），按优先级 P0→P1→P2 派发 dry-run
worker，回写 `currentStage/achievement/lastRun`，产出 `downloads/patrol-<ts>.json|.md`。
立即再跑：`lastRun` 已更新且未过 interval → due-list=0，演示 due 过滤生效。

## 换成真实 provider

实现同样的 `Get-PatrolItems / Save-PatrolItems / Resolve-ItemName` 三个函数，
数据源换成 Bitable（`lark-cli base`）或腾讯文档智能表格 API，调度器 `patrol-loop.ps1`
里只有 `Get-PatrolItems/Save-PatrolItems` 两处调用要换——其余 due-list/worker 池/
round 超时/互斥/digest 全不动。worker 的真实模式钩子见 `patrol-loop.ps1` 注释。