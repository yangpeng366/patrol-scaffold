#requires -Version 7
<#
    tests/verify-install-sync.ps1 — `scripts/sync-install.ps1` 的行为闸门（离线、%TEMP% 里现造仓，跑完删）

    为什么要有这道闸门：`sync-install` 是**会写文件**的工具，写错方向的代价不可逆（覆盖运行态、删掉本地
    扩展、把 CRLF 灌进安装目录）。所以它不能靠人读一遍代码就上线，必须把「写什么 / 不写什么 / 写几次」
    钉成断言：

      1) 干净副本：`written=0`（幂等，不无故重写）
      2) `-DryRun`：只打印 `[would-write]`，安装目录字节不变
      3) 漂移副本（篡改 1 字节 / 缺 1 文件 / 加 UTF-8 BOM）：`written=3`，`exit 0`
      4) 同步后交给 `tests/verify-install-drift.ps1` 实检：`missing=0 content=0 bom=0`，只剩 `extra`
         ——证明「同步」与「自检」两套口径同源，不是各说各话
      5) 运行时产物（`state/patrol-state.json`、`notify.log`）字节不变、也不被删
      6) 多出的本地扩展（`scripts/rogue.ps1`）不被删除、不被改写：删不删由人决定
      7) 连跑两次：第二次 `written=0`（幂等）
      8) CRLF 副本：同步后 `drift` 直接 PASS（换行符差异也是「按 HEAD 字节覆盖」能消掉的，不必手抠）
      9) 受控路径被目录占位：`exit 1` + `[blocked]` 点名，不静默跳过、也不删目录
     10) 环境错误：`-InstalledPath` 缺失 / 安装目录不存在 / RepoRoot 不是 git 仓 → `exit 2`

    用法：pwsh -NoProfile -File tests/verify-install-sync.ps1
    退出码：0 = 全绿；1 = 有断言失败；2 = 环境错误（缺 pwsh / 缺 git / 缺被检脚本）。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SyncScript = Join-Path $script:RepoRoot 'scripts\sync-install.ps1'
$script:DriftScript = Join-Path $script:RepoRoot 'tests\verify-install-drift.ps1'
$script:PwshExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($script:PwshExe) -or -not (Test-Path -LiteralPath $script:PwshExe)) { $script:PwshExe = 'pwsh' }
$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([string]$Label, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:Pass++; Write-Host ("[PASS] {0}{1}" -f $Label, $(if ($Detail) { "  $Detail" } else { '' })) }
    else { $script:Fail++; Write-Host ("[FAIL] {0}{1}" -f $Label, $(if ($Detail) { "  $Detail" } else { '' })) }
}

function Get-Sha256Hex {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-Child {
    param([string]$File, [string[]]$Arguments)
    $out = & $script:PwshExe -NoProfile -File $File @Arguments 2>&1
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($out | Out-String) }
}

function Get-SummaryCount {
    param([string]$Text, [string]$Key)
    $m = [regex]::Match($Text, ('\bsummary\b[^\r\n]*\b{0}=(-?\d+)' -f [regex]::Escape($Key)))
    if (-not $m.Success) { return $null }
    return [int]$m.Groups[1].Value
}

foreach ($required in @($script:SyncScript, $script:DriftScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Host ("RESULT: FAIL — 缺少被检脚本：{0}" -f $required)
        exit 2
    }
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-install-sync-' + [guid]::NewGuid().ToString('N'))
$exitCode = 0

try {
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    $repo = Join-Path $tmpRoot 'repo'
    foreach ($dir in @($repo, (Join-Path $repo 'scripts'), (Join-Path $repo 'docs'))) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $seed = [ordered]@{
        'VERSION'                   = "0.0.0`n"
        'SKILL.md'                  = "# 同步自证样本`n`n假的 skill 文档。`n"
        'scripts/patrol-loop.ps1'   = "Write-Output 'loop'`n"
        'scripts/sample-tasks.json' = "[{ `"id`": `"demo`" }]`n"
        'docs/notes.md'             = "notes`n"
    }
    foreach ($rel in $seed.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $repo ($rel -replace '/', '\')), $seed[$rel], $script:Utf8NoBom)
    }

    & git -C $repo init -q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '自证用 git init 失败：CLI 上没有可用的 git' }
    & git -C $repo -c core.autocrlf=false add -A 2>&1 | Out-Null
    & git -C $repo -c core.autocrlf=false -c user.name='install-sync-selftest' -c user.email='selftest@example.invalid' commit -q -m 'selftest baseline' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '自证用 git commit 失败（缺 user.name/user.email？）' }

    function New-InstallCopy {
        param([string]$Name)
        $dst = Join-Path $tmpRoot $Name
        Copy-Item -LiteralPath $repo -Destination $dst -Recurse -Force
        $gitDir = Join-Path $dst '.git'
        if (Test-Path -LiteralPath $gitDir) { Remove-Item -LiteralPath $gitDir -Recurse -Force }
        return $dst
    }

    # ---- a) 干净副本：不无故重写 ----
    $clean = New-InstallCopy 'a-clean'
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $clean)
    Assert-True 'a) 干净副本 written=0（幂等，不无谓重写）' `
        ($r.Exit -eq 0 -and (Get-SummaryCount $r.Text 'written') -eq 0 -and (Get-SummaryCount $r.Text 'unchanged') -eq $seed.Count) `
        ((($r.Text -split "`n") | Where-Object { $_ -match '^summary' }) -join '')

    # ---- b) 漂移副本：篡改 1 字节 / 缺 1 文件 / 加 BOM，另加运行时产物与本地扩展 ----
    $drifted = New-InstallCopy 'b-drifted'
    $loopPath = Join-Path $drifted 'scripts\patrol-loop.ps1'
    $loopBytes = [System.IO.File]::ReadAllBytes($loopPath)
    $loopBytes[0] = $loopBytes[0] -bxor 0x01
    [System.IO.File]::WriteAllBytes($loopPath, $loopBytes)
    Remove-Item -LiteralPath (Join-Path $drifted 'docs\notes.md') -Force
    $skillPath = Join-Path $drifted 'SKILL.md'
    $skillBytes = [System.IO.File]::ReadAllBytes($skillPath)
    [System.IO.File]::WriteAllBytes($skillPath, [byte[]]([byte[]](0xEF, 0xBB, 0xBF) + $skillBytes))
    $runtimeRel = @('state/patrol-state.json', 'notify.log')
    foreach ($rel in $runtimeRel) {
        $full = Join-Path $drifted ($rel -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
        [System.IO.File]::WriteAllText($full, "runtime`n", $script:Utf8NoBom)
    }
    $roguePath = Join-Path $drifted 'scripts\rogue.ps1'
    [System.IO.File]::WriteAllText($roguePath, "Write-Output 'local experiment'`n", $script:Utf8NoBom)
    $runtimeHashes = @{}
    foreach ($rel in $runtimeRel) { $runtimeHashes[$rel] = Get-Sha256Hex (Join-Path $drifted ($rel -replace '/', '\')) }
    $rogueHash = Get-Sha256Hex $roguePath
    $tamperedHash = Get-Sha256Hex $loopPath

    # b1) dry-run 不落盘
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $drifted, '-DryRun')
    $stillTampered = ((Get-Sha256Hex $loopPath) -eq $tamperedHash)
    $stillMissing = -not (Test-Path -LiteralPath (Join-Path $drifted 'docs\notes.md'))
    Assert-True 'b1) -DryRun 只打印 [would-write]，安装目录字节不变' `
        ($r.Exit -eq 0 -and $r.Text -match '\[would-write\]' -and (Get-SummaryCount $r.Text 'planned') -eq 3 -and (Get-SummaryCount $r.Text 'written') -eq 0 -and $stillTampered -and $stillMissing) `
        ("planned={0} written={1}" -f (Get-SummaryCount $r.Text 'planned'), (Get-SummaryCount $r.Text 'written'))

    # b2) 真同步：只写漂移的 3 个
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $drifted)
    Assert-True 'b2) 漂移副本 written=3 unchanged=2 且 exit 0' `
        ($r.Exit -eq 0 -and (Get-SummaryCount $r.Text 'written') -eq 3 -and (Get-SummaryCount $r.Text 'unchanged') -eq 2) `
        ((($r.Text -split "`n") | Where-Object { $_ -match '^summary' }) -join '')

    # b3) 同步结果交给 drift 闸门复核：缺/漂移/BOM 全消，只剩 extra
    $d = Invoke-Child -File $script:DriftScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $drifted, '-NoSelfTest')
    $cleanFindings = ($d.Text -match 'missing=0') -and ($d.Text -match 'content=0') -and ($d.Text -match 'bom=0')
    Assert-True 'b3) drift 复核：missing/content/bom 全为 0，只剩 extra' `
        ($cleanFindings -and $d.Exit -eq 1 -and $d.Text -match '\[FAIL\]\s+extra\s+scripts/rogue\.ps1') `
        ((($d.Text -split "`n") | Where-Object { $_ -match '^summary|\[FAIL\]' }) -join ' | ')

    # b4) 运行时产物与本地扩展：一字未动、一个没删
    $runtimeIntact = $true
    foreach ($rel in $runtimeRel) {
        $full = Join-Path $drifted ($rel -replace '/', '\')
        if (-not [System.IO.File]::Exists($full)) { $runtimeIntact = $false; break }
        if ((Get-Sha256Hex $full) -ne $runtimeHashes[$rel]) { $runtimeIntact = $false; break }
    }
    Assert-True 'b4) 运行时产物不被改写、不被删除' $runtimeIntact ("{0} 个" -f $runtimeRel.Count)
    Assert-True 'b5) 多出的本地扩展不被删除、不被改写' `
        ((Test-Path -LiteralPath $roguePath) -and ((Get-Sha256Hex $roguePath) -eq $rogueHash))

    # b6) 再跑一次：written=0
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $drifted)
    Assert-True 'b6) 连跑两次：第二次 written=0' `
        ($r.Exit -eq 0 -and (Get-SummaryCount $r.Text 'written') -eq 0) `
        ((($r.Text -split "`n") | Where-Object { $_ -match '^summary' }) -join '')

    # ---- c) CRLF 副本：同步后 drift 直接 PASS（换行符差异也按 HEAD 字节消掉）----
    $crlf = New-InstallCopy 'c-crlf'
    $crlfSkill = Join-Path $crlf 'SKILL.md'
    $text = [System.IO.File]::ReadAllText($crlfSkill, $script:Utf8NoBom)
    [System.IO.File]::WriteAllText($crlfSkill, ($text -replace "`r`n", "`n" -replace "`n", "`r`n"), $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $crlf 'VERSION'), "9.9.9`n", $script:Utf8NoBom)
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $crlf)
    $d = Invoke-Child -File $script:DriftScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $crlf, '-NoSelfTest')
    Assert-True 'c) CRLF + 版本漂移：同步后 drift 直接 PASS' `
        ($r.Exit -eq 0 -and $d.Exit -eq 0 -and $d.Text -match 'RESULT: PASS') `
        ("sync exit={0} drift exit={1}" -f $r.Exit, $d.Exit)

    # ---- d) 受控路径被目录占位：exit 1 + 点名，不删目录 ----
    $occupied = New-InstallCopy 'd-occupied'
    $occPath = Join-Path $occupied 'scripts\patrol-loop.ps1'
    Remove-Item -LiteralPath $occPath -Force
    New-Item -ItemType Directory -Force -Path $occPath | Out-Null
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $occupied)
    Assert-True 'd) 目录占位：exit 1 且 [blocked] 点名' `
        ($r.Exit -eq 1 -and $r.Text -match '\[blocked\]\s+scripts/patrol-loop\.ps1' -and (Test-Path -LiteralPath $occPath -PathType Container)) `
        ("exit={0}" -f $r.Exit)

    # ---- e) 环境错误一律 exit 2 ----
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo)
    Assert-True 'e1) 缺 -InstalledPath → exit 2' ($r.Exit -eq 2) ("exit={0}" -f $r.Exit)

    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', (Join-Path $tmpRoot 'nope'))
    Assert-True 'e2) 安装目录不存在 → exit 2' ($r.Exit -eq 2) ("exit={0}" -f $r.Exit)

    $nongit = Join-Path $tmpRoot 'e-nongit-repo'
    New-Item -ItemType Directory -Force -Path $nongit | Out-Null
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $nongit, '-InstalledPath', $clean)
    Assert-True 'e3) RepoRoot 不是 git 仓 → exit 2' ($r.Exit -eq 2) ("exit={0}" -f $r.Exit)

    # ---- f) 仓库本身当安装目录：拒绝（避免把运行时产物写进仓）----
    $r = Invoke-Child -File $script:SyncScript -Arguments @('-RepoRoot', $repo, '-InstalledPath', $repo)
    Assert-True 'f) -InstalledPath 指向仓库本身 → exit 2' ($r.Exit -eq 2) ("exit={0}" -f $r.Exit)
}
catch {
    Write-Host ("[FAIL] 自证异常：{0}" -f $_.Exception.Message)
    $script:Fail++
}
finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        $full = [System.IO.Path]::GetFullPath($tmpRoot)
        $tempPrefix = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($full.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ("summary pass={0} fail={1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { $exitCode = 1 }
Write-Host $(if ($exitCode -eq 0) { 'RESULT: PASS' } else { 'RESULT: FAIL' })
exit $exitCode
