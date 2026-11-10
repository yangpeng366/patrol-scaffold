#requires -Version 7
<#
    tests/verify-provider-isolation.ps1 — 多 provider 同进程同名函数互不串味（离线）。

    背景：四个 provider（bitable / local-json / tencent-docs / command）都定义同名的
    Get-PatrolItems / Save-PatrolItems / Resolve-ItemName。装配层早期只把「本次新增」的函数提升到
    脚本作用域，于是先装 bitable、再装 local-json 时，后者被前一家的同名函数遮住，
    报「A parameter cannot be found that matches parameter name 'TasksFile'」——
    adapter-contract-test 在 2026-11-10 之前一直是红的，只是没人跑。

    本脚本按「最坏顺序」装四家 provider（command 最后装：它无需凭据、可真跑），
    再回过头调用先装的那家，断言调用到的确实是它自己的实现。
    老实现必红，新实现（按 provider 复位函数集合）必绿。
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Label, [string]$Detail)
    if ($Condition) { Write-Host "PASS $Label"; $script:pass++ }
    else {
        Write-Host "FAIL $Label"
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "     $Detail" }
        $script:fail++
    }
}

. (Join-Path $repoRoot 'scripts\patrol-provider.ps1')

$tasksFile = Join-Path $repoRoot 'scripts\sample-tasks.json'

try {
    $bitable = Import-PatrolProvider -Provider 'bitable' -Values @{ configPath = 'placeholder-not-used' }
    $tx = Import-PatrolProvider -Provider 'tencent-docs' -Values @{ configPath = 'placeholder-not-used' }
    $local = Import-PatrolProvider -Provider 'local-json' -Values @{ tasksFile = $tasksFile }
    # command 最后装：无需凭据、可真跑，是验「后装的不会把先装的搞坏、先装的也不会被后装的顶替」的最好样本
    $command = Import-PatrolProvider -Provider 'command' -Values @{ tasksFile = $tasksFile }
    Assert-True ($null -ne $bitable -and $null -ne $tx -and $null -ne $local -and $null -ne $command) 'import: 四家 provider 在同一进程里都装载成功'

    # 关键断言：最后装的是 local-json，但 local-json 的契约函数必须真的能被调用（不被前两家遮住）
    $items = @(Get-PatrolProviderItems -Provider $local)
    Assert-True ($items.Count -gt 0) ('list-items: local-json 返回 {0} 行' -f $items.Count) '返回 0 行或抛错'

    $named = @($items | Where-Object { [string]$_.id -and [string]$_.title })
    Assert-True ($named.Count -eq $items.Count) ('schema: {0}/{1} 行同时有 id 与 title' -f $named.Count, $items.Count)

    $nm = Resolve-PatrolProviderName -Provider $local -Item $items[0]
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$nm)) ('resolve-name: local-json -> {0}' -f $nm)

    # 再装一次 local-json，验证复位是幂等的（重复装配不会把函数搞丢）
    $local2 = Import-PatrolProvider -Provider 'local-json' -Values @{ tasksFile = $tasksFile }
    $items2 = @(Get-PatrolProviderItems -Provider $local2)
    Assert-True ($items2.Count -eq $items.Count) ('idempotent: 二次装配后仍是 {0} 行' -f $items2.Count) ('期望 {0} 行，实得 {1}' -f $items.Count, $items2.Count)

    # 反过来：装完 local-json 后重新调用先装的 bitable 对象，也必须切回 bitable 的实现。
    # 不联网：只比对装上的函数集合，不跑 list-items（bitable 需要凭据）。
    $bitableFnBody = if ($bitable.ModuleFns -and $bitable.ModuleFns['Get-PatrolItems']) { $bitable.ModuleFns['Get-PatrolItems'].ToString() } else { '' }
    $localFnBody = if ($local.ModuleFns -and $local.ModuleFns['Get-PatrolItems']) { $local.ModuleFns['Get-PatrolItems'].ToString() } else { '' }
    Assert-True ($bitableFnBody.Length -gt 0 -and $localFnBody.Length -gt 0) 'registry: 两家 provider 各自记住了自己的 Get-PatrolItems'
    Assert-True ($bitableFnBody -ne $localFnBody) 'registry: bitable 与 local-json 的 Get-PatrolItems 实现不同（确非同名同体）'

    # command（最后装的一家）必须真的跑在自己的实现上：返回 mock 命令的 3 行，而不是 local-json 的行数
    $cmdItems = @(Get-PatrolProviderItems -Provider $command)
    Assert-True ($cmdItems.Count -eq 3) ('list-items: command 返回 {0} 行（mock 命令 3 行）' -f $cmdItems.Count) '返回 0 行或抛错'
    Assert-True ((($cmdItems | ForEach-Object { $_.id }) -join ',') -eq 'job-101,job-102,job-103') 'command: 行来自 mock 命令（job-101..103），未串到别家的数据' (($cmdItems | ForEach-Object { $_.id }) -join ',')
    $cmdName = Resolve-PatrolProviderName -Provider $command -Item $cmdItems[0]
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$cmdName)) ('resolve-name: command -> {0}' -f $cmdName)

    # 再切回先装的 local-json：后装过 command 之后，调用仍须落到 local-json 自己的实现
    $itemsBack = @(Get-PatrolProviderItems -Provider $local)
    Assert-True ($itemsBack.Count -eq $items.Count) ('switch-back: 装过 command 后再调 local-json 仍是 {0} 行' -f $items.Count) ('期望 {0} 行，实得 {1}' -f $items.Count, $itemsBack.Count)
    $cmdFnBody = if ($command.ModuleFns -and $command.ModuleFns['Get-PatrolItems']) { $command.ModuleFns['Get-PatrolItems'].ToString() } else { '' }
    Assert-True ($cmdFnBody.Length -gt 0 -and $cmdFnBody -ne $localFnBody) 'registry: command 的 Get-PatrolItems 与 local-json 的实现不同'
} catch {
    $fail++
    Write-Host ('FAIL exception: {0}' -f $_.Exception.Message)
}

Write-Host ('summary pass={0} fail={1}' -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
