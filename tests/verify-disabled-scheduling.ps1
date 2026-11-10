#requires -Version 7
<#
.SYNOPSIS
  tests/verify-disabled-scheduling.ps1 — 「intervalMin 0 / 空 / 缺列 / 负数 = 停跑」的调度层闸门。

.DESCRIPTION
  背景：方向表里 0 值行普遍写「停跑 / 停用 / 只读留档」，但本仓旧调度器把 `<=0` 回退成
  60 分钟，等于让已停项目每 60 分钟被复活一次。生产口径已定：**0 = 停跑，空/缺列 = 停跑**。
  本脚本把这条口径钉成会红的闸门——不看文档、不看注释，只喂 fixture 给真函数看结果。

  被测对象是 scripts/patrol-schedule.ps1 的 Get-PatrolDueSelection（patrol-loop.ps1 直接
  dot-source 同一个文件，所以这里测的就是生产路径，不是副本）。

  覆盖（fixture 行）：
    intervalMin=0            + lastRun 2 小时前  -> disabled（不进 due）
    intervalMin 缺列          + lastRun 2 小时前  -> disabled
    intervalMin=-15          + lastRun 2 小时前  -> disabled
    intervalMin=$null        + lastRun 2 小时前  -> disabled
    intervalMin=''           + lastRun 2 小时前  -> disabled
    intervalMin=90           + lastRun 30 分钟前 -> 未到期（既非 due 也非 disabled）
    intervalMin=90           + lastRun 3 小时前  -> due
    intervalMin=1            + lastRun 缺列      -> due（没跑过就是到期）
    intervalMin=90           + lastRun=null      -> due

  断言：集合相等（due / disabled 逐 id）+ 单点分支 + 三者分区完整（due+disabled+pending=行数）。

  自证（默认开启，-NoSelfTest 关闭）：在 %TEMP% 造 3 个变异副本，断言闸门自己会红——
    A) 去掉 `<=0` 跳过（只判 null）      -> 0 与负数漏进 due，必须 FAIL 且点名「0 -> 停跑」
    B) 恢复旧口径 `<=0 -> 60`（回退）    -> 0 与负数漏进 due，必须 FAIL 且点名「0 -> 停跑」
    C) `lastRun` 空时 `continue`（漏派）  -> 没跑过的行不再到期，必须 FAIL 且点名「lastRun 空」
  变异只落在 %TEMP%，仓库零污染；变异锚点找不到即 FAIL（防止源码改形后自证悄悄失效）。

  用法：
    pwsh -NoProfile -File tests/verify-disabled-scheduling.ps1
    pwsh -NoProfile -File tests/verify-disabled-scheduling.ps1 -NoSelfTest
    pwsh -NoProfile -File tests/verify-disabled-scheduling.ps1 -Module D:\path\patrol-schedule.ps1

  退出码：0 = PASS（或 SKIP 之外的全绿），1 = FAIL。输出末行 `RESULT: PASS/FAIL`。
#>
param(
    # 被测模块；默认 <repo>/scripts/patrol-schedule.ps1
    [string]$Module = '',
    [switch]$NoSelfTest
)

$ErrorActionPreference = 'Stop'
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:FixtureNow = [datetime]'2026-11-11T12:00:00'
$script:Pass = 0
$script:Fail = 0

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Module) { $Module = Join-Path (Join-Path $repoRoot 'scripts') 'patrol-schedule.ps1' }

$ExpectedDue = @('row-nolast-1', 'row-nolast-90', 'row-stale-90')
$ExpectedDisabled = @('row-empty', 'row-missing', 'row-negative', 'row-null', 'row-zero')

function Write-Check {
    param([bool]$Ok, [string]$Label, [string]$Detail = '')
    $suffix = if ($Detail) { " - $Detail" } else { '' }
    if ($Ok) {
        Write-Host ("PASS {0}{1}" -f $Label, $suffix)
        $script:Pass++
    }
    else {
        Write-Host ("FAIL {0}{1}" -f $Label, $suffix)
        $script:Fail++
    }
}

function New-Check {
    param([bool]$Ok, [string]$Label, [string]$Detail = '')
    return [pscustomobject]@{ Ok = $Ok; Label = $Label; Detail = $Detail }
}

function Test-SetEqual {
    param([string[]]$Left, [string[]]$Right)
    $l = @($Left | Sort-Object -Unique)
    $r = @($Right | Sort-Object -Unique)
    if ($l.Count -ne $r.Count) { return $false }
    for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -ne $r[$i]) { return $false } }
    return $true
}

function New-Row {
    param(
        [string]$Id,
        $Interval = '__ABSENT__',
        $LastRun = '__ABSENT__'
    )
    $row = [ordered]@{ id = $Id; title = $Id; priority = 'P1' }
    if ([string]$Interval -ne '__ABSENT__') { $row['intervalMin'] = $Interval }
    if ([string]$LastRun -ne '__ABSENT__') { $row['lastRun'] = $LastRun }
    return [pscustomobject]$row
}

<#
    fixture 行固定为一个「相对 $script:FixtureNow 的时刻表」，于是结论与跑测时间无关。
    row-missing 故意不给 intervalMin 属性（缺列），row-empty 给空串，两者都不是 0 但同样停跑。
#>
function New-FixtureRows {
    $now = $script:FixtureNow
    return @(
        (New-Row -Id 'row-zero' -Interval 0 -LastRun $now.AddHours(-2).ToString('o')),
        (New-Row -Id 'row-missing' -LastRun $now.AddHours(-2).ToString('o')),
        (New-Row -Id 'row-negative' -Interval -15 -LastRun $now.AddHours(-2).ToString('o')),
        (New-Row -Id 'row-null' -Interval $null -LastRun $now.AddHours(-2).ToString('o')),
        (New-Row -Id 'row-empty' -Interval '' -LastRun $now.AddHours(-2).ToString('o')),
        (New-Row -Id 'row-fresh-90' -Interval 90 -LastRun $now.AddMinutes(-30).ToString('o')),
        (New-Row -Id 'row-stale-90' -Interval 90 -LastRun $now.AddHours(-3).ToString('o')),
        (New-Row -Id 'row-nolast-1' -Interval 1),
        (New-Row -Id 'row-nolast-90' -Interval 90 -LastRun $null)
    )
}

<#
    dot-source 被测模块后立刻在同一作用域里调用，测的就是这个文件里的函数。
    （dot-source 的函数落在本函数作用域内，调用方拿不到，也避免多次 dot-source 互相污染。）
#>
function Get-FixtureSelection {
    param([string]$ModulePath)
    . $ModulePath
    $rows = @(New-FixtureRows)
    $selection = Get-PatrolDueSelection -Items $rows -Now $script:FixtureNow
    return [pscustomobject]@{
        Rows     = $rows
        Due      = @($selection.Due)
        Disabled = @($selection.Disabled)
    }
}

function Test-FixtureSemantics {
    param($Selection)

    $dueIds = @($Selection.Due | ForEach-Object { [string]$_.id })
    $disabledIds = @($Selection.Disabled | ForEach-Object { [string]$_.id })
    $allIds = @($Selection.Rows | ForEach-Object { [string]$_.id })
    $pendingIds = @($allIds | Where-Object { ($dueIds -notcontains $_) -and ($disabledIds -notcontains $_) })

    $inDue = { param([string]$id) $dueIds -contains $id }
    $inDisabled = { param([string]$id) $disabledIds -contains $id }
    $labels = [ordered]@{
        'row-zero'     = 'intervalMin=0'
        'row-missing'  = 'intervalMin 缺列'
        'row-negative' = 'intervalMin=-15'
        'row-null'     = 'intervalMin=null'
        'row-empty'    = 'intervalMin 空串'
    }

    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($id in $labels.Keys) {
        $isDisabled = (& $inDisabled $id)
        $isDue = (& $inDue $id)
        $checks.Add((New-Check (($isDisabled) -and (-not $isDue)) ("{0} -> 停跑（只进 disabled，不进 due）" -f $labels[$id]) ("disabled={0} due={1}" -f $isDisabled, $isDue)))
    }

    $freshDue = (& $inDue 'row-fresh-90')
    $freshDisabled = (& $inDisabled 'row-fresh-90')
    $checks.Add((New-Check ((-not $freshDue) -and (-not $freshDisabled)) 'intervalMin=90 且 lastRun 刚跑过 -> 未到期（既非 due 也非 disabled）' ("due={0} disabled={1}" -f $freshDue, $freshDisabled)))

    $staleDue = (& $inDue 'row-stale-90')
    $checks.Add((New-Check $staleDue 'intervalMin=90 且 lastRun 超期 -> 到期' ("due={0}" -f $staleDue)))

    $nolastDue = (& $inDue 'row-nolast-1')
    $checks.Add((New-Check $nolastDue 'intervalMin=1 且 lastRun 空 -> 到期' ("due={0}" -f $nolastDue)))

    $nolastNullDue = (& $inDue 'row-nolast-90')
    $checks.Add((New-Check $nolastNullDue 'intervalMin=90 且 lastRun=null -> 到期' ("due={0}" -f $nolastNullDue)))

    $checks.Add((New-Check (Test-SetEqual $dueIds $ExpectedDue) 'due 集合 = 期望集合' ('got=[' + ($dueIds -join ',') + '] want=[' + ($ExpectedDue -join ',') + ']')))
    $checks.Add((New-Check (Test-SetEqual $disabledIds $ExpectedDisabled) 'disabled 集合 = 期望集合' ('got=[' + ($disabledIds -join ',') + '] want=[' + ($ExpectedDisabled -join ',') + ']')))

    $partitionOk = (($dueIds.Count + $disabledIds.Count + $pendingIds.Count) -eq $allIds.Count)
    $countOk = (($dueIds.Count -eq 3) -and ($disabledIds.Count -eq 5) -and ($pendingIds.Count -eq 1))
    $checks.Add((New-Check ($partitionOk -and $countOk) '分区完整：due=3 disabled=5 pending=1 且三者和 = 行数' ("due={0} disabled={1} pending={2} rows={3}" -f $dueIds.Count, $disabledIds.Count, $pendingIds.Count, $allIds.Count)))

    $disjoint = @($dueIds | Where-Object { $disabledIds -contains $_ }).Count -eq 0
    $checks.Add((New-Check $disjoint 'due 与 disabled 不相交' ('overlap=[' + (@($dueIds | Where-Object { $disabledIds -contains $_ }) -join ',') + ']')))

    return $checks.ToArray()
}

function New-MutantModule {
    param([string]$SourcePath, [string]$DestinationPath, [string[]]$Replacements)
    $text = [System.IO.File]::ReadAllText($SourcePath, $script:Utf8)
    for ($i = 0; $i -lt $Replacements.Count; $i += 2) {
        $from = $Replacements[$i]
        $to = $Replacements[$i + 1]
        if (-not $text.Contains($from)) { throw ("变异锚点找不到（源码改形了？）：{0}" -f $from) }
        $text = $text.Replace($from, $to)
    }
    [System.IO.File]::WriteAllText($DestinationPath, $text, $script:Utf8)
}

<#
    变异自证：把「跳过」逻辑改坏（A/B）或把「lastRun 空 -> 到期」改坏（C），
    闸门必须判红，且必须点名到具体那一条断言。
#>
function Invoke-MutantCheck {
    param([string]$MutantPath, [string[]]$Replacements, [string]$ExpectFailFragment)

    New-MutantModule -SourcePath $Module -DestinationPath $MutantPath -Replacements $Replacements
    try {
        $selection = Get-FixtureSelection -ModulePath $MutantPath
        $checks = @(Test-FixtureSemantics -Selection $selection)
        $failed = @($checks | Where-Object { -not $_.Ok })
        $named = @($failed | Where-Object { $_.Label -like ('*' + $ExpectFailFragment + '*') })
        return [pscustomobject]@{
            Failed = $failed
            Named = $named.Count -gt 0
            Ok     = ($failed.Count -gt 0) -and ($named.Count -gt 0)
            Detail = ("failed={0} named={1} first=[{2}]" -f $failed.Count, ($named.Count -gt 0), $(if ($failed.Count -gt 0) { $failed[0].Label } else { '' }))
        }
    }
    catch {
        return [pscustomobject]@{ Failed = @(); Named = $false; Ok = $false; Detail = ("mutant threw: {0}" -f $_.Exception.Message) }
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
Write-Host 'disabled-scheduling gate: intervalMin 0 / 空 / 缺列 / 负数 = 停跑（不进入 due）'
Write-Host ('module = {0}' -f $Module)
Write-Host ('fixture now = {0:o}（结论与跑测时刻无关）' -f $script:FixtureNow)

if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
    Write-Host ('FAIL 被测模块不存在：{0}' -f $Module)
    Write-Host 'RESULT: FAIL'
    exit 1
}

$selection = $null
try {
    $selection = Get-FixtureSelection -ModulePath $Module
}
catch {
    Write-Host ('FAIL 被测模块报错：{0}' -f $_.Exception.Message)
    Write-Host 'RESULT: FAIL'
    exit 1
}

foreach ($check in @(Test-FixtureSemantics -Selection $selection)) {
    Write-Check $check.Ok $check.Label $check.Detail
}
Write-Host ('summary pass={0} fail={1}' -f $script:Pass, $script:Fail)

$selfFail = 0
if ($NoSelfTest) {
    Write-Host 'selftest: skipped (-NoSelfTest)'
}
else {
    Write-Host '== selftest（%TEMP% 里的变异副本必须判红）=='
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-disabled-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    try {
        $guard = '        if (($null -eq $interval) -or ($interval -le 0)) { $disabled.Add($it); continue }'
        $nolast = '        if ($null -eq $last) { $due.Add($it); continue }'

        $mutants = @(
            @{
                Name       = 'A) 去掉 <=0 跳过（停跑判断失效）'
                Path       = Join-Path $sandbox 'mutant-a.ps1'
                Replace    = @($guard, '        if (($null -eq $interval) -or $false) { $disabled.Add($it); continue }')
                ExpectFail = 'intervalMin=0 -> 停跑'
            },
            @{
                Name       = 'B) 恢复旧口径 <=0 -> 60（每 60 分钟复活）'
                Path       = Join-Path $sandbox 'mutant-b.ps1'
                Replace    = @($guard, "        if (`$null -eq `$interval) { `$disabled.Add(`$it); continue }`n        if (`$interval -le 0) { `$interval = 60 }")
                ExpectFail = 'intervalMin=0 -> 停跑'
            },
            @{
                Name       = 'C) lastRun 空时不再到期（漏派没跑过的行）'
                Path       = Join-Path $sandbox 'mutant-c.ps1'
                Replace    = @($nolast, '        if ($null -eq $last) { continue }')
                ExpectFail = 'lastRun 空'
            }
        )

        foreach ($m in $mutants) {
            $r = Invoke-MutantCheck -MutantPath $m.Path -Replacements $m.Replace -ExpectFailFragment $m.ExpectFail
            if ($r.Ok) {
                Write-Host ('PASS selftest: {0} -> 闸门判红并点名（{1}）' -f $m.Name, $r.Detail)
            }
            else {
                Write-Host ('FAIL selftest: {0} -> 变异没被抓住（{1}）' -f $m.Name, $r.Detail)
                $selfFail++
            }
        }
    }
    catch {
        Write-Host ('FAIL selftest setup: {0}' -f $_.Exception.Message)
        $selfFail++
    }
    finally {
        $full = [System.IO.Path]::GetFullPath($sandbox)
        $prefix = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if (($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) -and (Test-Path -LiteralPath $full)) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host ('summary selftest fail={0}' -f $selfFail)
}

$exitCode = 0
if (($script:Fail -gt 0) -or ($selfFail -gt 0)) { $exitCode = 1 }
Write-Host ('RESULT: {0}' -f $(if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }))
exit $exitCode
