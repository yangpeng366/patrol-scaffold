#requires -Version 7
<#
.SYNOPSIS
  Verify that patrol runtime state is externalized.

.DESCRIPTION
  Runs patrol-loop twice against a TEMP copy of sample-tasks.json and a TEMP
  state file. The source copy must stay byte-identical; the first run is fully
  due, the second is not due because lastRun comes from the state file.
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sample = Join-Path $root 'scripts\sample-tasks.json'
$encoding = [System.Text.UTF8Encoding]::new($false)

$tmpRoot = Join-Path $env:TEMP ('patrol-state-test-' + [guid]::NewGuid().ToString('N'))
$skillTmp = Join-Path $tmpRoot 'skill'
$scriptsTmp = Join-Path $skillTmp 'scripts'
$adaptersTmp = Join-Path $skillTmp 'adapters'
foreach ($dir in @($tmpRoot, $scriptsTmp, $adaptersTmp)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$tasksCopy = Join-Path $tmpRoot 'sample-tasks.json'
$stateFile = Join-Path $tmpRoot 'state\patrol-state.json'
$failures = 0

function Assert-Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $suffix = if ($Detail) { " - $Detail" } else { '' }
    if ($Condition) {
        Write-Host ("PASS {0}{1}" -f $Name, $suffix)
    } else {
        Write-Host ("FAIL {0}{1}" -f $Name, $suffix)
        $script:failures++
    }
}

try {
    # Run a byte-for-byte copy of the loop tree in TEMP so digest/memory outputs
    # never land in the repository.
    foreach ($name in @('patrol-loop.ps1', 'patrol-provider.ps1', 'patrol-state.ps1', 'patrol-schedule.ps1', 'local-json-adapter.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "scripts\$name") -Destination (Join-Path $scriptsTmp $name) -Force
    }
    foreach ($name in @('JevShadow.ps1', 'Invoke-ItemJevDecision.ps1', 'JevDecision.ps1')) {
        $optional = Join-Path $root "scripts\$name"
        if (Test-Path -LiteralPath $optional) {
            Copy-Item -LiteralPath $optional -Destination (Join-Path $scriptsTmp $name) -Force
        }
    }
    Copy-Item -LiteralPath (Join-Path $root 'adapters\local-json.adapter.json') -Destination (Join-Path $adaptersTmp 'local-json.adapter.json') -Force
    $loop = Join-Path $scriptsTmp 'patrol-loop.ps1'

    Copy-Item -LiteralPath $sample -Destination $tasksCopy -Force

    # Older versions wrote run state back into sample-tasks.json. Normalize the
    # TEMP copy to the 3-row baseline (lastRun empty) so this test measures the
    # state contract, not whatever dirt the working tree currently carries.
    # intervalMin=0 现在是「停跑」（见 tests/verify-disabled-scheduling.ps1），停跑行不派发也就
    # 不会被回写 lastRun，本测试要验的是「source 只读 + 运行态外置」，所以把基线行的间隔改成正值。
    $baseline = @(@(Get-Content -LiteralPath $tasksCopy -Raw | ConvertFrom-Json) | Select-Object -First 3)
    if ($baseline.Count -ne 3) { throw "sample-tasks.json needs at least 3 rows, got $($baseline.Count)" }
    foreach ($item in $baseline) {
        foreach ($field in @('lastRun', 'currentStage', 'achievement', 'threadId')) {
            $item.$field = $null
        }
        $item.intervalMin = 60
    }
    [System.IO.File]::WriteAllText($tasksCopy, ($baseline | ConvertTo-Json -Depth 8 -AsArray), $encoding)

    $beforeHash = (Get-FileHash -LiteralPath $tasksCopy -Algorithm SHA256).Hash

    $out1 = (& pwsh -NoProfile -File $loop -TasksFile $tasksCopy -StateFile $stateFile -Once -DryRun 2>&1 | Out-String)
    $code1 = $LASTEXITCODE
    $out2 = (& pwsh -NoProfile -File $loop -TasksFile $tasksCopy -StateFile $stateFile -Once -DryRun 2>&1 | Out-String)
    $code2 = $LASTEXITCODE

    $afterHash = (Get-FileHash -LiteralPath $tasksCopy -Algorithm SHA256).Hash
    $due1 = if ($out1 -match 'due=(\d+/\d+) disabled=(\d+)') { $Matches[1] } else { 'missing' }
    $disabled1 = if ($out1 -match 'due=(\d+/\d+) disabled=(\d+)') { $Matches[2] } else { 'missing' }
    $due2 = if ($out2 -match 'due=(\d+/\d+) disabled=(\d+)') { $Matches[1] } else { 'missing' }
    $disabled2 = if ($out2 -match 'due=(\d+/\d+) disabled=(\d+)') { $Matches[2] } else { 'missing' }

    Assert-Check 'a) source copy SHA256 unchanged' ($beforeHash -eq $afterHash) ("before=$beforeHash after=$afterHash exit1=$code1 exit2=$code2")
    Assert-Check 'b) first run due=3/3, second run due=0/3' (($code1 -eq 0) -and ($code2 -eq 0) -and ($due1 -eq '3/3') -and ($due2 -eq '0/3')) ("run1=$due1 run2=$due2 exit1=$code1 exit2=$code2")
    Assert-Check 'd) 基线行间隔为正值，disabled=0（没有行因停跑被跳过）' (($disabled1 -eq '0') -and ($disabled2 -eq '0')) ("disabled1=$disabled1 disabled2=$disabled2")

    $stateExists = Test-Path -LiteralPath $stateFile
    $records = @()
    if ($stateExists) { $records = @(Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) }
    $incomplete = @($records | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_.id) -or [string]::IsNullOrWhiteSpace([string]$_.lastRun)
    })
    Assert-Check 'c) temp state json has 3 records with id + lastRun' ($stateExists -and ($records.Count -eq 3) -and ($incomplete.Count -eq 0)) ("exists=$stateExists records=$($records.Count) incomplete=$($incomplete.Count)")
} catch {
    Write-Host ("FAIL setup/run: {0}" -f $_.Exception.Message)
    $script:failures++
} finally {
    $fullTmp = [System.IO.Path]::GetFullPath($tmpRoot)
    $tempPrefix = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($fullTmp.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fullTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -eq 0) {
    Write-Host 'state externalization: PASS'
    exit 0
}
Write-Host ("state externalization: FAIL ({0} assertion(s))" -f $failures)
exit 1
