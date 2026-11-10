#requires -Version 7
<#
  tests/fixtures/command/mock-jobs.ps1 — provider=command 的 mock 命令（无网络、无凭据、确定性输出）。

  模拟「某个 CLI 的 jobs list --json」：stdout 是一段 JSON 数组，字段名与 item 契约不同
  （jobId / jobName / state / intervalMin），靠描述文件里的 fieldMap 重映射。

  用法（适配器内部由子进程执行，工作目录 = 仓库根）：
    pwsh -NoProfile -File tests/fixtures/command/mock-jobs.ps1
    pwsh -NoProfile -File tests/fixtures/command/mock-jobs.ps1 -Count 1

  刻意不读网络、不写文件、不看时钟：CI 上可重复，断言可以写死。
#>
param(
    [ValidateRange(1, 100)]
    [int]$Count = 3
)

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

$all = @(
    [ordered]@{
        jobId       = 'job-101'
        jobName     = 'SCNet 队列巡检'
        state       = '进行中'
        intervalMin = 30
        priority    = 'P0'
        nextStep    = '核对队列配额'
        note        = '来源：mock scnet jobs list --json'
        repo        = $repoRoot
    }
    [ordered]@{
        jobId       = 'job-102'
        jobName     = '数据库导出对账'
        state       = '待开始'
        intervalMin = 60
        priority    = 'P1'
        nextStep    = '对齐昨日导出'
        note        = '来源：mock sqlite3 导出'
        repo        = $repoRoot
    }
    [ordered]@{
        jobId       = 'job-103'
        jobName     = 'CLI 版本漂移检查'
        state       = '待开始'
        intervalMin = 0
        priority    = 'P2'
        nextStep    = '固定版本号'
        note        = 'interval=0 表示每轮都到期'
        repo        = ''
    }
)

$rows = @($all | Select-Object -First $Count)
ConvertTo-Json -InputObject @($rows) -Depth 4
