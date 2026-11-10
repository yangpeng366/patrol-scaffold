#requires -Version 7
<#
.SYNOPSIS
  build-release.ps1 — 生成可复现、可检查的发布归档（默认落到 %TEMP%，不入仓）。

.DESCRIPTION
  本仓没有 package.json，也没有构建步骤：发布物就是「仓库受控文件 + 本轮新增文件」的一个 zip。
  本脚本把「打包」变成一条可重跑、会自证的命令，而不是手工右键压缩。

  它做四件事：
    1) 定版本：读 VERSION（唯一事实源），要求 CHANGELOG.md 里真有 `## [<version>]` 一节。
    2) 定清单：`git ls-files`（受控）+ 未跟踪且未被 .gitignore 忽略的文件（需 -IncludeUntracked 显式确认），
       逐条校验路径相对、文件存在且非空；所有 adapter 的 module 必须在这份清单里。
    3) 定内容：用户自有改动（默认 `scripts/sample-tasks.json`）**不采用工作区字节**，
       改为从 HEAD 取 blob。理由是它是用户的未提交改动，不属于本次发布；
       这条不是口头承诺——打包后逐字节比对 HEAD blob（见「验证」）。
    4) 打包 + 自证：按路径排序、固定时间戳写 zip，附 SHA256SUMS.txt，
       再重新打开 zip 校验：条目集合 == 清单、逐条哈希、禁入模式（.git / state / downloads /
       reports / *.zip / *.log / 临时文件）、VERSION 与 CHANGELOG 一致、sample-tasks.json == HEAD blob，
       最后把归档解到 %TEMP% 里用仓内 `tests/verify-no-secrets.ps1` 扫一遍（可选 -SkipSecretScan）。

  可复现的口径（别过度承诺）：
    - 同一台机器、同一 .NET / PowerShell 7 版本、同一份输入 → 两次构建的 zip SHA256 相同
      （路径排序固定、条目不写额外字段、时间戳固定为 HEAD 提交时间）。
    - 跨机器 / 跨 .NET 版本不保证 zip 字节相同（Deflate 实现可能不同）；跨机器请比对
      `SHA256SUMS.txt` 的逐文件哈希，那才是内容等价性的判据。

.PARAMETER OutputDirectory
  归档输出目录，默认 `%TEMP%\patrol-scaffold-release`。不要指到仓库内——zip 已被 .gitignore 覆盖，
  但仍不该把发布物放在工作树里。

.PARAMETER Version
  仅用于「确认」，不能用来改版本：值必须与 VERSION 文件相同，否则报错。

.PARAMETER IncludeUntracked
  把未跟踪且未被忽略的文件一并打包。默认关闭：有未跟踪文件时直接失败并列出，
  避免把临时脚本 / 本地笔记误打进去。发布新文件时显式带上这个开关。

.PARAMETER HeadSourcedPaths
  这些路径只从 HEAD 取内容，忽略工作区改动。默认 `scripts/sample-tasks.json`（用户自有改动）。

.PARAMETER SkipSecretScan
  跳过「解包后跑 verify-no-secrets.ps1」这一步（只跳过扫描，其它校验照跑）。

.EXAMPLE
  pwsh -NoProfile -File scripts/build-release.ps1 -IncludeUntracked

.EXAMPLE
  pwsh -NoProfile -File scripts/build-release.ps1 -Version 0.2.0 -OutputDirectory D:\drop
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'patrol-scaffold-release'),
    [string]$Version = '',
    [switch]$IncludeUntracked,
    [string[]]$HeadSourcedPaths = @('scripts/sample-tasks.json'),
    [switch]$SkipSecretScan,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Checks = [ordered]@{}

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:Checks[$Name] = [pscustomobject]@{ Ok = $Ok; Detail = $Detail }
    $label = if ($Ok) { 'ok' } else { 'FAIL' }
    Write-Host ("verify {0,-18} {1}{2}" -f $Name, $label, $(if ($Detail) { "  $Detail" } else { '' }))
}

function Stop-Release {
    param([string]$Message)
    Write-Host "RESULT: FAIL"
    throw $Message
}

# ---------------------------------------------------------------------------
# git 调用（文本 / 原始字节分开：zip 与 sha256 都不能经过 PowerShell 的文本管道）
# ---------------------------------------------------------------------------
function New-GitProcess {
    param([string[]]$Arguments)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    foreach ($a in @('-C', $RepoRoot) + $Arguments) { $psi.ArgumentList.Add([string]$a) }
    return [System.Diagnostics.Process]::Start($psi)
}

function Invoke-GitText {
    param([string[]]$Arguments)
    $p = New-GitProcess -Arguments $Arguments
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $out = $outTask.GetAwaiter().GetResult()
    $err = $errTask.GetAwaiter().GetResult()
    if ($p.ExitCode -ne 0) { Stop-Release ("git {0} 失败（exit={1}）：{2}" -f ($Arguments -join ' '), $p.ExitCode, $err.Trim()) }
    return @($out -split "`r?`n" | Where-Object { $_ -ne '' })
}

function Get-GitBlobBytes {
    param([string]$Path)
    $p = New-GitProcess -Arguments @('cat-file', 'blob', "HEAD:$Path")
    $ms = [System.IO.MemoryStream]::new()
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        $err = $p.StandardError.ReadToEnd()
        Stop-Release ("取 HEAD:$Path 失败（exit={0}）：{1}" -f $p.ExitCode, $err.Trim())
    }
    return $ms.ToArray()
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256Hex {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

# ---------------------------------------------------------------------------
# 1) 版本
# ---------------------------------------------------------------------------
$versionFile = Join-Path $RepoRoot 'VERSION'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { Stop-Release "找不到 VERSION：$versionFile" }
$fileVersion = ([System.IO.File]::ReadAllText($versionFile, $script:Utf8NoBom)).Trim()
if ($fileVersion -notmatch '^\d+\.\d+\.\d+$') { Stop-Release "VERSION 不是 x.y.z 形态：'$fileVersion'" }
if ($Version -and $Version -ne $fileVersion) {
    Stop-Release ("-Version {0} 与 VERSION 文件的 {1} 不一致；版本只能改 VERSION 文件（唯一事实源）" -f $Version, $fileVersion)
}
$Version = $fileVersion
Add-Check 'version' $true "VERSION=$Version"

$changelogPath = Join-Path $RepoRoot 'CHANGELOG.md'
if (-not (Test-Path -LiteralPath $changelogPath -PathType Leaf)) { Stop-Release "找不到 CHANGELOG.md：$changelogPath" }
$changelog = [System.IO.File]::ReadAllText($changelogPath, $script:Utf8NoBom)
$hasSection = [regex]::IsMatch($changelog, ('(?m)^##\s+\[' + [regex]::Escape($Version) + '\](\s|$)'))
Add-Check 'changelog' $hasSection $(if ($hasSection) { "CHANGELOG 有 [$Version] 一节" } else { "CHANGELOG 缺 [$Version] 一节" })
if (-not $hasSection) { Stop-Release "CHANGELOG.md 里没有 [$Version] 一节：先写变更说明再打包" }

$headInfo = Invoke-GitText -Arguments @('log', '-1', '--format=%H%n%ct')
$headCommit = @($headInfo)[0]
$headEpoch = [int64](@($headInfo)[1])

# ---------------------------------------------------------------------------
# 2) 清单
# ---------------------------------------------------------------------------
$tracked = @(Invoke-GitText -Arguments @('ls-files'))
$untracked = @(Invoke-GitText -Arguments @('ls-files', '--others', '--exclude-standard'))
if ($untracked.Count -gt 0 -and -not $IncludeUntracked) {
    Write-Host '未跟踪且未被忽略的文件：'
    foreach ($u in $untracked) { Write-Host "  + $u" }
    Stop-Release '有未跟踪文件。确属本次发布内容请加 -IncludeUntracked，否则先清理或写入 .gitignore'
}
$manifest = @(@($tracked) + @($untracked) | Sort-Object -Unique)
if ($manifest.Count -eq 0) { Stop-Release '清单为空：git ls-files 没有返回任何文件' }

foreach ($rel in $manifest) {
    if ($rel -match '^[/\\]' -or $rel -match '(^|[/\\])\.\.([/\\]|$)' -or $rel -match '^[A-Za-z]:') {
        Stop-Release "清单里出现非相对路径：$rel"
    }
    $full = Join-Path $RepoRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Stop-Release "清单里的文件不存在：$rel" }
    if ((Get-Item -LiteralPath $full).Length -eq 0) { Stop-Release "清单里的文件是 0 字节：$rel" }
}

$forbiddenPatterns = @(
    '(^|/)(\.git|\.hg|\.svn|\.idea|\.vscode|__pycache__|node_modules)(/|$)',
    '(^|/)(downloads|state|reports|memory|jev-shadow-hooks)(/|$)',
    '\.(zip|7z|tar|gz|tgz|tmp|temp|log|bak|orig|swp|pyc)$',
    '(^|/)~\$',
    '(^|/)(Thumbs\.db|\.DS_Store|desktop\.ini)$',
    '(^|/)patrol-state\.json$',
    '(^|/)command-mirror\.json$'
)
$forbiddenHits = @($manifest | Where-Object {
        $rel = $_
        @($forbiddenPatterns | Where-Object { [regex]::IsMatch($rel, $_, 'IgnoreCase') }).Count -gt 0
    })
Add-Check 'no-runtime-files' ($forbiddenHits.Count -eq 0) $(if ($forbiddenHits.Count -eq 0) { "$($manifest.Count) 条路径无运行时/临时指纹" } else { "命中：" + ($forbiddenHits -join ', ') })
if ($forbiddenHits.Count -gt 0) { Stop-Release '清单里混入运行时产物或临时文件：打包会污染发布物' }

# adapter 的 module 必须随包分发（否则装完即坏）
$adapterFiles = @($manifest | Where-Object { $_ -match '^adapters/.*\.adapter\.json$' })
if ($adapterFiles.Count -eq 0) { Stop-Release '清单里没有 adapters/*.adapter.json' }
$missingModules = @()
foreach ($af in $adapterFiles) {
    $d = [System.IO.File]::ReadAllText((Join-Path $RepoRoot ($af -replace '/', '\')), $script:Utf8NoBom) | ConvertFrom-Json
    $m = ([string]$d.module) -replace '\\', '/'
    if (-not $m) { $missingModules += "${af}: module 为空"; continue }
    if ($manifest -notcontains $m) { $missingModules += "${af}: $m" }
}
Add-Check 'adapter-modules' ($missingModules.Count -eq 0) $(if ($missingModules.Count -eq 0) { "$($adapterFiles.Count) 个描述文件的 module 都在清单内" } else { $missingModules -join '; ' })
if ($missingModules.Count -gt 0) { Stop-Release 'adapter 模块未随包分发' }

Add-Check 'manifest' $true ("files={0}（tracked={1} new={2}）" -f $manifest.Count, $tracked.Count, $untracked.Count)
foreach ($u in $untracked) { Write-Host "  new file: $u" }

# HEAD 取内容的路径必须是受控文件
$headSourced = @()
foreach ($h in @($HeadSourcedPaths)) {
    $h = $h -replace '\\', '/'
    if (-not $h) { continue }
    if ($tracked -notcontains $h) { Stop-Release "HeadSourcedPaths 里的 '$h' 不是受控文件，无法从 HEAD 取内容" }
    $headSourced += $h
}

# ---------------------------------------------------------------------------
# 3) 暂存（字节复制，不重编码）
# ---------------------------------------------------------------------------
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-release-stage-' + [guid]::NewGuid().ToString('N'))
$pkgName = "patrol-scaffold-$Version"
$pkgDir = Join-Path $stageRoot $pkgName
New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null

$userChanged = @()
try {
    foreach ($rel in $manifest) {
        $dest = Join-Path $pkgDir ($rel -replace '/', '\')
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        if ($headSourced -contains $rel) {
            [System.IO.File]::WriteAllBytes($dest, (Get-GitBlobBytes -Path $rel))
            $wt = Join-Path $RepoRoot ($rel -replace '/', '\')
            $wtHash = Get-FileSha256Hex -Path $wt
            $headHash = Get-FileSha256Hex -Path $dest
            if ($wtHash -ne $headHash) { $userChanged += $rel }
        }
        else {
            [System.IO.File]::Copy((Join-Path $RepoRoot ($rel -replace '/', '\')), $dest, $true)
        }
    }

    # SHA256SUMS.txt：内容清单 + 逐文件哈希（跨机器可比对的判据）
    $sumsPath = Join-Path $pkgDir 'SHA256SUMS.txt'
    $lines = @()
    foreach ($rel in $manifest) {
        $h = Get-FileSha256Hex -Path (Join-Path $pkgDir ($rel -replace '/', '\'))
        $lines += ('{0}  {1}' -f $h, $rel)
    }
    [System.IO.File]::WriteAllText($sumsPath, (($lines -join "`n") + "`n"), $script:Utf8NoBom)
    $entries = @($manifest + 'SHA256SUMS.txt')

    # 固定时间戳（HEAD 提交时间）：同一份输入两次构建应得到同一份 zip
    $fixedTime = [System.DateTimeOffset]::FromUnixTimeSeconds($headEpoch).ToLocalTime()

    # -----------------------------------------------------------------------
    # 4) 打包（自己建条目：顺序与时间戳可控）
    # -----------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null }
    $zipPath = Join-Path $OutputDirectory ("{0}.zip" -f $pkgName)
    if (Test-Path -LiteralPath $zipPath) {
        try { Remove-Item -LiteralPath $zipPath -Force }
        catch { Stop-Release "已有归档被占用，关掉再重跑：$zipPath" }
    }

    $zipStream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false, $script:Utf8NoBom)
        try {
            foreach ($rel in @($entries | Sort-Object)) {
                $src = Join-Path $pkgDir ($rel -replace '/', '\')
                $entry = $zip.CreateEntry(("{0}/{1}" -f $pkgName, $rel), [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $fixedTime
                $es = $entry.Open()
                $fs = [System.IO.File]::OpenRead($src)
                try { $fs.CopyTo($es) } finally { $fs.Dispose(); $es.Dispose() }
            }
        }
        finally { $zip.Dispose() }
    }
    finally { $zipStream.Dispose() }

    # -----------------------------------------------------------------------
    # 5) 自证：重新打开归档，逐项校验
    # -----------------------------------------------------------------------
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { ($_.FullName -replace '\\', '/') })
        $badPath = @($entryNames | Where-Object { $_ -notmatch ('^' + [regex]::Escape($pkgName) + '/') -or $_ -match '\.\.' })
        Add-Check 'archive-paths' ($badPath.Count -eq 0) $(if ($badPath.Count -eq 0) { "$($entryNames.Count) 个条目都在 $pkgName/ 下" } else { $badPath -join ', ' })
        if ($badPath.Count -gt 0) { Stop-Release '归档里有越界条目' }

        $relNames = @($entryNames | ForEach-Object { $_.Substring($pkgName.Length + 1) })
        $expected = @($entries | Sort-Object)
        $got = @($relNames | Sort-Object)
        $missing = @($expected | Where-Object { $got -notcontains $_ })
        $extra = @($got | Where-Object { $expected -notcontains $_ })
        Add-Check 'archive-manifest' (($missing.Count -eq 0) -and ($extra.Count -eq 0)) $(if (($missing.Count -eq 0) -and ($extra.Count -eq 0)) { "缺失=0 多出=0" } else { "缺失：$($missing -join ',') 多出：$($extra -join ',')" })
        if (($missing.Count -gt 0) -or ($extra.Count -gt 0)) { Stop-Release '归档条目与清单不一致' }

        $hashMismatch = @()
        foreach ($e in $archive.Entries) {
            $rel = ($e.FullName -replace '\\', '/')
            $rel = $rel.Substring($pkgName.Length + 1)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $s = $e.Open()
            try { $hash = ([System.BitConverter]::ToString($sha.ComputeHash($s))).Replace('-', '').ToLowerInvariant() }
            finally { $s.Dispose(); $sha.Dispose() }
            $local = Get-FileSha256Hex -Path (Join-Path $pkgDir ($rel -replace '/', '\'))
            if ($hash -ne $local) { $hashMismatch += $rel }
        }
        Add-Check 'archive-hashes' ($hashMismatch.Count -eq 0) $(if ($hashMismatch.Count -eq 0) { "$($archive.Entries.Count) 个条目与暂存区逐字节一致" } else { $hashMismatch -join ', ' })
        if ($hashMismatch.Count -gt 0) { Stop-Release '归档条目哈希不一致' }

        $forbiddenInZip = @($relNames | Where-Object {
                $rel = $_
                @($forbiddenPatterns | Where-Object { [regex]::IsMatch($rel, $_, 'IgnoreCase') }).Count -gt 0
            })
        Add-Check 'archive-clean' ($forbiddenInZip.Count -eq 0) $(if ($forbiddenInZip.Count -eq 0) { '无 .git / state / downloads / reports / *.zip / 临时文件' } else { $forbiddenInZip -join ', ' })
        if ($forbiddenInZip.Count -gt 0) { Stop-Release '归档里有运行时产物或临时文件' }

        $versionEntry = $archive.GetEntry("$pkgName/VERSION")
        $versionText = ''
        if ($versionEntry) {
            $sr = [System.IO.StreamReader]::new($versionEntry.Open(), $script:Utf8NoBom)
            try { $versionText = $sr.ReadToEnd().Trim() } finally { $sr.Dispose() }
        }
        Add-Check 'archive-version' ($versionText -eq $Version) "归档内 VERSION='$versionText'"

        $sampleEntry = $archive.GetEntry("$pkgName/scripts/sample-tasks.json")
        $sampleOk = $false; $sampleDetail = '归档内没有 scripts/sample-tasks.json'
        if ($sampleEntry) {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $s = $sampleEntry.Open()
            try { $archiveHash = ([System.BitConverter]::ToString($sha.ComputeHash($s))).Replace('-', '').ToLowerInvariant() }
            finally { $s.Dispose(); $sha.Dispose() }
            $headHash = Get-Sha256Hex -Bytes (Get-GitBlobBytes -Path 'scripts/sample-tasks.json')
            $sampleOk = ($archiveHash -eq $headHash)
            $sampleDetail = "归档={0} HEAD={1}（工作区不采用）" -f $archiveHash.Substring(0, 12), $headHash.Substring(0, 12)
        }
        Add-Check 'user-changes-out' $sampleOk $sampleDetail
        if (-not $sampleOk) { Stop-Release 'scripts/sample-tasks.json 与 HEAD 不一致：用户未提交改动混进了发布物' }
    }
    finally { $archive.Dispose() }

    $zipSha = (Get-FileSha256Hex -Path $zipPath)
    $zipLen = (Get-Item -LiteralPath $zipPath).Length

    # 可选：把归档解到 %TEMP%，用仓内门禁扫一遍密钥（扫的是产物，不是工作区）
    if (-not $SkipSecretScan) {
        $scanRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-release-scan-' + [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $scanRoot, $script:Utf8NoBom)
            $scanDir = Join-Path $scanRoot $pkgName
            # 用小段 Push-Location + 原生 git 调用（不走 New-GitProcess：那里已经预置 -C $RepoRoot，
            # 再叠一个 -C 会让 git 在错误的仓里枚举，实测会挂住）。
            $prevLocation = Get-Location
            Push-Location -LiteralPath $scanDir
            try {
                & git init -q 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Stop-Release '解包目录 git init 失败，密钥扫描未执行' }
                # fixtures 在 .gitignore 里（受控但被忽略），必须 -f 才会进索引，否则扫描范围会漏
                & git add -A -f 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Stop-Release '解包目录 git add 失败，密钥扫描未执行' }
            }
            finally { Pop-Location }

            $scanOut = & pwsh -NoProfile -File (Join-Path $scanDir 'tests\verify-no-secrets.ps1') 2>&1 | Out-String
            $scanExit = $LASTEXITCODE
            $scanSummary = ($scanOut -split "`r?`n" | Where-Object { $_ -match '^summary ' }) -join ' | '
            Add-Check 'artifact-secrets' ($scanExit -eq 0) $(if ($scanExit -eq 0) { $scanSummary } else { "exit=$scanExit $scanSummary" })
            if ($scanExit -ne 0) {
                Write-Host $scanOut
                Stop-Release '发布物里有密钥卫生命中'
            }
        }
        finally {
            if (Test-Path -LiteralPath $scanRoot) { Remove-Item -LiteralPath $scanRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    else {
        Add-Check 'artifact-secrets' $true 'skipped (-SkipSecretScan)'
    }

    # -----------------------------------------------------------------------
    # 报告
    # -----------------------------------------------------------------------
    $sidecar = "$zipPath.sha256"
    [System.IO.File]::WriteAllText($sidecar, ("{0}  {1}`n" -f $zipSha, (Split-Path -Leaf $zipPath)), $script:Utf8NoBom)

    Write-Host ''
    Write-Host ("release      : patrol-scaffold {0}" -f $Version)
    Write-Host ("base commit  : {0}" -f $headCommit.Substring(0, 7))
    Write-Host ("files        : {0} (+SHA256SUMS.txt = {1} entries)" -f $manifest.Count, ($manifest.Count + 1))
    Write-Host ("head-sourced : {0}{1}" -f (($headSourced -join ', ')), $(if ($userChanged.Count -gt 0) { '  ← 工作区改动已排除：' + ($userChanged -join ', ') } else { '' }))
    Write-Host ("archive      : {0}" -f $zipPath)
    Write-Host ("bytes        : {0}" -f $zipLen)
    Write-Host ("sha256       : {0}" -f $zipSha)
    Write-Host ("sidecar      : {0}" -f $sidecar)

    $status = @(Invoke-GitText -Arguments @('status', '--short'))
    Write-Host 'git status --short（打包时）：'
    if ($status.Count -eq 0) { Write-Host '  <clean>' } else { foreach ($s in $status) { Write-Host "  $s" } }

    $failed = @($script:Checks.Keys | Where-Object { -not $script:Checks[$_].Ok })
    if ($failed.Count -gt 0) { Stop-Release ("校验未通过：{0}" -f ($failed -join ', ')) }

    Write-Host 'RESULT: PASS'
}
finally {
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
