#requires -Version 7
<#
    tests/verify-install-drift.ps1 — 安装后 / 升级后自检：已安装 skill 必须与仓库 HEAD 逐字节一致

    为什么要有这个门禁：本仓的发布物就是「受控文件的一份拷贝」，安装 = 把目录拷到
    `$CODEX_HOME\skills\patrol-scaffold`。此前 skill 同步完之后只能靠人工比对哈希，
    装错版本、漏装新文件、编辑器加 BOM、把本地实验脚本一起拷进去，都不会有人报错——
    要等到某一轮巡检跑歪了才发现。本脚本把这件事变成一条可复跑、会红的命令。

    比对口径（刻意写死，不靠口头约定）：
      - 受控文件 = 仓库 HEAD 的 blob（`git ls-tree -r HEAD`，只取普通文件，跳过符号链接），
        **不是工作区字节**。理由：`scripts/sample-tasks.json` 是用户自有未提交改动，
        拿工作区比会把用户数据当成安装漂移；发布物也是从 HEAD 取它的。
      - 每个受控文件逐文件比 SHA256：仓库 HEAD blob vs 安装目录实际字节。
      - 安装目录允许保留运行时产物（`downloads/`、`memory/`、`state/`、`reports/`、`*.log`、
        `patrol-state.json`、`command-mirror.json`、`SHA256SUMS.txt` 等），它们既不算漂移，
        **也不会被本脚本删除或改写**——本脚本对安装目录只读。
      - 缺文件 / 类型不是文件 / 内容漂移 / UTF-8 BOM 不一致 / 不可读 / 多出的受控或源码文件
        都要点名报出并 `exit 1`。

    自证（默认随主流程跑，`-NoSelfTest` 关掉）：在 %TEMP% 造一个真 git 仓（含 6 个受控文件、
    其中一份故意模仿 `scripts/sample-tasks.json`），再逐场景复制安装目录，断言「干净副本 PASS /
    篡改一个字节 FAIL 并点名 / 缺文件 FAIL 并点名 / 运行态多余文件不误报且不被删除 /
    多余源码文件 FAIL / BOM 能报出 / 工作区脏但安装等于 HEAD 仍 PASS（证明以 HEAD 为准）/
    不可读文件 FAIL 且句柄释放后恢复 PASS / `-ManifestFile` 只查清单内 / `-ExcludePath` 生效 /
    换行符差异点明」。末尾把自证仓再往前推两个提交，专测两类版本迁移事故：
    「另一处 codex-home 的旧版完整副本落后一个提交、缺新文件 -> 点名该新文件」与
    「升级后新旧两版并存、留有已改名的旧受控脚本 -> 点名多出的旧文件」。临时目录 finally 删除。

    用法：
      # 1) 只跑自证（CI / 无本机安装时）
      pwsh -NoProfile -File tests/verify-install-drift.ps1

      # 2) 实检本机已安装 skill
      pwsh -NoProfile -File tests/verify-install-drift.ps1 -InstalledPath "$env:CODEX_HOME\skills\patrol-scaffold"

      # 3) 只查清单里的子集（例如平台相关文件不参与比对）
      pwsh -NoProfile -File tests/verify-install-drift.ps1 -InstalledPath <dir> -ManifestFile .\drift-manifest.txt
      pwsh -NoProfile -File tests/verify-install-drift.ps1 -InstalledPath <dir> -ExcludePath 'docs/*.md'

    退出码：0 = PASS；1 = 有漂移或自证失败；2 = 用法/环境错误（不是 git 仓、安装目录不存在等）。

    运行环境：仅 PowerShell 7（pwsh）+ git。源码 UTF-8 无 BOM。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$InstalledPath = '',
    [string]$ManifestFile = '',
    [string[]]$ExcludePath = @(),
    [switch]$NoSelfTest
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:BomBytes = [byte[]](0xEF, 0xBB, 0xBF)

# 安装目录里允许存在的运行时产物：不算漂移、不参与比对、绝不删除。
# 与 .gitignore / build-release.ps1 的禁入模式同源，避免「发布不让带、安装又报红」两头打架。
$script:RuntimePatterns = @(
    '^\.git(/|$)',
    '^(downloads|memory|state|reports|scripts/downloads|scripts/memory)(/|$)',
    '^jev-shadow-hooks(/|$)',
    '(^|/)patrol-state\.json$',
    '(^|/)command-mirror\.json$',
    '^SHA256SUMS\.txt$',
    '\.(log|tmp|temp|zip|7z|sha256|pyc|orig|bak|swp)$',
    '(^|/)~\$',
    '(^|/)__pycache__(/|$)',
    '(^|/)(Thumbs\.db|\.DS_Store|desktop\.ini)$'
)

$script:ExcludePatterns = @()
foreach ($pattern in @($ExcludePath)) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
    $script:ExcludePatterns += [System.Management.Automation.WildcardPattern]::new(
        ([string]$pattern).Trim(),
        [System.Management.Automation.WildcardOptions]::IgnoreCase)
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
function ConvertTo-RelativeKey {
    param([string]$Path)
    return (($Path -replace '\\', '/').TrimStart('/'))
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-Utf8Bom {
    param([byte[]]$Bytes)
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function Remove-Utf8Bom {
    param([byte[]]$Bytes)
    if ($Bytes.Length -le 3) { return [byte[]]::new(0) }
    $out = [byte[]]::new($Bytes.Length - 3)
    [System.Array]::Copy($Bytes, 3, $out, 0, $out.Length)
    return $out
}

# 只用于把「换行符差异」和「真内容漂移」分开说清楚，不参与判定（返回值是哈希串，避免数组进出函数的坑）
function Get-LfNormalizedSha256Hex {
    param([byte[]]$Bytes)
    $buffer = [byte[]]::new($Bytes.Length)
    $n = 0
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 0x0D -and ($i + 1) -lt $Bytes.Length -and $Bytes[$i + 1] -eq 0x0A) { continue }
        $buffer[$n] = $Bytes[$i]
        $n++
    }
    if ($n -eq 0) { return (Get-Sha256Hex -Bytes ([byte[]]::new(0))) }
    $trimmed = [byte[]]::new($n)
    [System.Array]::Copy($buffer, 0, $trimmed, 0, $n)
    return (Get-Sha256Hex -Bytes $trimmed)
}

function Test-RuntimePath {
    param([string]$Rel)
    foreach ($pattern in $script:RuntimePatterns) {
        if ([regex]::IsMatch($Rel, $pattern, 'IgnoreCase')) { return $true }
    }
    return $false
}

function Test-ExcludedPath {
    param([string]$Rel)
    foreach ($wp in $script:ExcludePatterns) {
        if ($wp.IsMatch($Rel)) { return $true }
    }
    return $false
}

# git 必须走原生进程：blob 是二进制，经过 PowerShell 文本管道会被重编码
function Invoke-GitRaw {
    param([string]$Repo, [string[]]$Arguments)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $Repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    foreach ($a in @('-C', $Repo) + $Arguments) { $psi.ArgumentList.Add([string]$a) }
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = [System.IO.MemoryStream]::new()
    $errTask = $p.StandardError.ReadToEndAsync()
    try { $p.StandardOutput.BaseStream.CopyTo($ms) } catch { }
    $p.WaitForExit()
    $err = $errTask.GetAwaiter().GetResult()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $ms.ToArray(); Err = [string]$err }
}

# ---------------------------------------------------------------------------
# 受控清单：HEAD blob（默认）或显式清单文件
# ---------------------------------------------------------------------------
function Get-ControlledEntries {
    param([string]$RepoRoot, [string]$ManifestFile)

    $entries = [System.Collections.Generic.List[object]]::new()

    if ($ManifestFile) {
        if (-not [System.IO.File]::Exists($ManifestFile)) { throw "清单文件不存在：$ManifestFile" }
        foreach ($line in [System.IO.File]::ReadAllLines($ManifestFile, $script:Utf8NoBom)) {
            $text = $line.Trim()
            if ($text -eq '' -or $text.StartsWith('#')) { continue }
            $rel = ConvertTo-RelativeKey $text
            if ($rel -match '^[A-Za-z]:' -or $rel -match '(^|/)\.\.(/|$)') {
                throw "清单里有非相对路径：$text"
            }
            $entries.Add([pscustomobject]@{ Path = $rel })
        }
        return $entries.ToArray()
    }

    $result = Invoke-GitRaw -Repo $RepoRoot -Arguments @('ls-tree', '-r', '-z', 'HEAD')
    if ($result.ExitCode -ne 0) {
        throw ("git ls-tree HEAD 失败（exit={0}）：{1}" -f $result.ExitCode, $result.Err.Trim())
    }
    $text = $script:Utf8NoBom.GetString($result.Out)
    foreach ($record in ($text -split "`0")) {
        if ($record -eq '') { continue }
        $meta, $path = $record -split "`t", 2
        if ([string]::IsNullOrEmpty($path)) { continue }
        $parts = $meta -split ' '
        if ($parts.Count -lt 2) { continue }
        if ($parts[1] -ne 'blob') { continue }
        # 符号链接（120000）在 Windows 上没有可比的「文件字节」，跳过并单独计数
        if ($parts[0] -eq '120000') { continue }
        $entries.Add([pscustomobject]@{ Path = (ConvertTo-RelativeKey $path) })
    }
    return $entries.ToArray()
}

# ---------------------------------------------------------------------------
# 核心比对：给定仓库 + 安装目录，返回发现项（纯函数，自证直接复用）
# ---------------------------------------------------------------------------
function Invoke-InstallDriftCheck {
    param(
        [string]$RepoRoot,
        [string]$InstalledPath,
        [string]$ManifestFile = '',
        [switch]$Quiet
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $installFull = [System.IO.Path]::GetFullPath($InstalledPath).TrimEnd('\', '/')
    $entries = @(Get-ControlledEntries -RepoRoot $RepoRoot -ManifestFile $ManifestFile)

    # 大小写不敏感：Windows 文件系统本身不区分，避免同文件双写被当成 extra
    $manifestSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $checked = 0
    $excluded = 0

    foreach ($entry in $entries) {
        $rel = $entry.Path
        if ($rel -eq '') { continue }
        [void]$manifestSet.Add($rel)

        if (Test-ExcludedPath -Rel $rel) { $excluded++; continue }
        $checked++

        $full = Join-Path $installFull ($rel -replace '/', '\')
        if (-not [System.IO.File]::Exists($full)) {
            $kind = if ([System.IO.Directory]::Exists($full)) { 'not-a-file' } else { 'missing' }
            $findings.Add([pscustomobject]@{ Kind = $kind; Path = $rel; Detail = '' })
            continue
        }

        $head = Invoke-GitRaw -Repo $RepoRoot -Arguments @('cat-file', 'blob', "HEAD:$rel")
        if ($head.ExitCode -ne 0) {
            throw ("取 HEAD:{0} 失败（exit={1}）：{2}" -f $rel, $head.ExitCode, $head.Err.Trim())
        }
        $headBytes = $head.Out

        try { $installedBytes = [System.IO.File]::ReadAllBytes($full) }
        catch {
            $findings.Add([pscustomobject]@{
                    Kind   = 'unreadable'
                    Path   = $rel
                    Detail = ("{0}: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message)
                })
            continue
        }

        $headHash = Get-Sha256Hex -Bytes $headBytes
        $installedHash = Get-Sha256Hex -Bytes $installedBytes
        if ($headHash -eq $installedHash) { continue }

        # 先判 BOM：只有「去掉 BOM 后逐字节相同」才算 BOM 类漂移，否则是真正的内容漂移
        $headHasBom = Test-Utf8Bom -Bytes $headBytes
        $installedHasBom = Test-Utf8Bom -Bytes $installedBytes
        if ($headHasBom -ne $installedHasBom) {
            $headBody = if ($headHasBom) { Remove-Utf8Bom -Bytes $headBytes } else { $headBytes }
            $installedBody = if ($installedHasBom) { Remove-Utf8Bom -Bytes $installedBytes } else { $installedBytes }
            if ((Get-Sha256Hex -Bytes $headBody) -eq (Get-Sha256Hex -Bytes $installedBody)) {
                $detail = if ($installedHasBom) { '安装侧多出 UTF-8 BOM（受控源码应为无 BOM）' } else { '安装侧缺少 UTF-8 BOM（HEAD 有 BOM）' }
                $findings.Add([pscustomobject]@{ Kind = 'bom'; Path = $rel; Detail = $detail })
                continue
            }
        }

        # 换行符差异仍然是 FAIL（逐字节口径），但要在 detail 里说清，否则会被当成神秘的内容漂移
        $eolOnly = ((Get-LfNormalizedSha256Hex -Bytes $headBytes) -eq (Get-LfNormalizedSha256Hex -Bytes $installedBytes))
        $detail = if ($eolOnly) {
            ('仅换行符不同（HEAD 与安装侧 CRLF/LF 不一致）bytes={0}/{1}' -f $headBytes.Length, $installedBytes.Length)
        }
        else {
            ('head={0} installed={1} bytes={2}/{3}' -f $headHash.Substring(0, 12), $installedHash.Substring(0, 12), $headBytes.Length, $installedBytes.Length)
        }
        $findings.Add([pscustomobject]@{ Kind = 'content'; Path = $rel; Detail = $detail })
    }

    # 多出来的文件：受控文件之外、又不是运行时产物 —— 源码/配置类的多余文件才是漂移
    $enumErrors = @()
    $files = @(Get-ChildItem -LiteralPath $installFull -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable +enumErrors)
    foreach ($file in $files) {
        $rel = ConvertTo-RelativeKey $file.FullName.Substring($installFull.Length).TrimStart('\', '/')
        if ($rel -eq '') { continue }
        if ($manifestSet.Contains($rel)) { continue }
        if (Test-ExcludedPath -Rel $rel) { continue }
        if (Test-RuntimePath -Rel $rel) { continue }
        $findings.Add([pscustomobject]@{ Kind = 'extra'; Path = $rel; Detail = '' })
    }
    foreach ($err in $enumErrors) {
        $target = [string]$err.TargetObject
        $findings.Add([pscustomobject]@{
                Kind   = 'unreadable'
                Path   = (ConvertTo-RelativeKey $target)
                Detail = ("目录枚举失败：{0}" -f $err.Exception.Message)
            })
    }

    $counts = [ordered]@{ missing = 0; 'not-a-file' = 0; content = 0; bom = 0; extra = 0; unreadable = 0 }
    foreach ($f in $findings) { $counts[$f.Kind] = [int]$counts[$f.Kind] + 1 }

    return [pscustomobject]@{
        Checked  = $checked
        Excluded = $excluded
        Findings = @($findings)
        Counts   = $counts
        Ok       = ($findings.Count -eq 0)
    }
}

function Write-DriftReport {
    param([pscustomobject]$Result, [string]$InstalledPath)
    foreach ($finding in $Result.Findings) {
        $suffix = if ($finding.Detail) { '  ' + $finding.Detail } else { '' }
        Write-Host ("[FAIL] {0,-10} {1}{2}" -f $finding.Kind, $finding.Path, $suffix)
    }
    $c = $Result.Counts
    Write-Host ("summary checked={0} ok={1} fail={2} missing={3} not-a-file={4} content={5} bom={6} extra={7} unreadable={8} excluded={9}" -f `
            $Result.Checked, ($Result.Checked - ($Result.Findings.Count)), $Result.Findings.Count, `
            $c['missing'], $c['not-a-file'], $c['content'], $c['bom'], $c['extra'], $c['unreadable'], $Result.Excluded)
    if ($Result.Findings.Count -gt 0) {
        Write-Host ("安装目录：{0}" -f $InstalledPath)
        Write-Host '提示：缺文件补齐、内容漂移/BOM 用该文件在 HEAD 的字节覆盖；多余源码文件先确认是否本地扩展（本地扩展应放仓外）。'
        Write-Host '本自检只读，未改动安装目录里的任何文件（含 downloads/ memory/ notify.log 等运行时产物）。'
    }
}

# ---------------------------------------------------------------------------
# 自证
# ---------------------------------------------------------------------------
$script:SelfPass = 0
$script:SelfFail = 0

function Assert-DriftSelfTest {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:SelfPass++
        Write-Host ("[PASS] selftest {0}{1}" -f $Name, $(if ($Detail) { "  $Detail" } else { '' }))
    }
    else {
        $script:SelfFail++
        Write-Host ("[FAIL] selftest {0}{1}" -f $Name, $(if ($Detail) { "  $Detail" } else { '' }))
    }
}

function Get-FindingDetail {
    param([pscustomobject]$Result)
    if ($Result.Findings.Count -eq 0) { return '无发现项' }
    return (($Result.Findings | ForEach-Object { '{0}:{1}' -f $_.Kind, $_.Path }) -join ', ')
}

function Invoke-DriftSelfTest {
    param([string]$Root)

    $repo = Join-Path $Root 'repo'
    foreach ($dir in @($repo, (Join-Path $repo 'scripts'), (Join-Path $repo 'adapters'), (Join-Path $repo 'docs'))) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $seed = [ordered]@{
        'VERSION'                         = "0.0.0`n"
        'SKILL.md'                        = "# 自证样本`n`n用于 install-drift 自证的假 skill，不是真实文档。`n"
        'scripts/patrol-loop.ps1'         = "Write-Output 'loop'`n"
        'scripts/sample-tasks.json'       = "[{ `"id`": `"demo`", `"intervalMin`": 0 }]`n"
        'adapters/selftest.adapter.json'  = "{ `"provider`": `"selftest`" }`n"
        'docs/notes.md'                   = "notes`n"
    }
    foreach ($rel in $seed.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $repo ($rel -replace '/', '\')), $seed[$rel], $script:Utf8NoBom)
    }

    & git -C $repo init -q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '自证用 git init 失败：CLI 上没有可用的 git' }
    & git -C $repo -c core.autocrlf=false add -A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '自证用 git add 失败' }
    & git -C $repo -c core.autocrlf=false -c user.name='install-drift-selftest' -c user.email='selftest@example.invalid' commit -q -m 'selftest baseline' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '自证用 git commit 失败（缺 user.name/user.email？）' }

    function New-InstallCopy {
        param([string]$Name)
        $dst = Join-Path $Root $Name
        Copy-Item -LiteralPath $repo -Destination $dst -Recurse -Force
        $gitDir = Join-Path $dst '.git'
        if (Test-Path -LiteralPath $gitDir) { Remove-Item -LiteralPath $gitDir -Recurse -Force }
        return $dst
    }

    # a) 干净副本必须 PASS
    $clean = New-InstallCopy 'a-clean'
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $clean -Quiet
    Assert-DriftSelfTest 'a) 干净副本 PASS' ($r.Ok -and $r.Checked -eq $seed.Count) ("checked=$($r.Checked)/$($seed.Count) " + (Get-FindingDetail $r))

    # b) 运行时产物既不许误报，也不许被删
    $runtime = New-InstallCopy 'b-runtime'
    $runtimeFiles = @(
        'downloads/patrol-20261111.json',
        'memory/kb.md',
        'state/patrol-state.json',
        'reports/digest.md',
        'notify.log',
        'scripts/downloads/patrol-20261111.md',
        'SHA256SUMS.txt'
    )
    foreach ($rel in $runtimeFiles) {
        $full = Join-Path $runtime ($rel -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
        [System.IO.File]::WriteAllText($full, "runtime`n", $script:Utf8NoBom)
    }
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $runtime -Quiet
    Assert-DriftSelfTest 'b) 多余运行时文件不误报' ($r.Ok -and @($r.Findings | Where-Object { $_.Kind -eq 'extra' }).Count -eq 0) (Get-FindingDetail $r)
    $survivors = @($runtimeFiles | Where-Object { [System.IO.File]::Exists((Join-Path $runtime ($_ -replace '/', '\'))) })
    Assert-DriftSelfTest 'b2) 自检不删除运行时文件' ($survivors.Count -eq $runtimeFiles.Count) ("保留={0}/{1}" -f $survivors.Count, $runtimeFiles.Count)

    # c) 篡改一个字节：必须 FAIL 且点名该文件
    $tampered = New-InstallCopy 'c-tamper'
    $target = Join-Path $tampered 'scripts\patrol-loop.ps1'
    $bytes = [System.IO.File]::ReadAllBytes($target)
    $bytes[0] = $bytes[0] -bxor 0x01
    [System.IO.File]::WriteAllBytes($target, $bytes)
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $tampered -Quiet
    $hit = @($r.Findings | Where-Object { $_.Kind -eq 'content' -and $_.Path -eq 'scripts/patrol-loop.ps1' })
    Assert-DriftSelfTest 'c) 篡改一个字节 FAIL 且点名文件' ((-not $r.Ok) -and $hit.Count -eq 1 -and $r.Findings.Count -eq 1) (Get-FindingDetail $r)

    # d) 缺文件：必须 FAIL 且点名
    $incomplete = New-InstallCopy 'd-missing'
    Remove-Item -LiteralPath (Join-Path $incomplete 'adapters\selftest.adapter.json') -Force
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $incomplete -Quiet
    $hit = @($r.Findings | Where-Object { $_.Kind -eq 'missing' -and $_.Path -eq 'adapters/selftest.adapter.json' })
    Assert-DriftSelfTest 'd) 缺文件 FAIL 且点名文件' ((-not $r.Ok) -and $hit.Count -eq 1 -and $r.Findings.Count -eq 1) (Get-FindingDetail $r)

    # e) 多出的源码文件：必须 FAIL 且点名
    $polluted = New-InstallCopy 'e-extra'
    [System.IO.File]::WriteAllText((Join-Path $polluted 'scripts\rogue.ps1'), "Write-Output 'local experiment'`n", $script:Utf8NoBom)
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $polluted -Quiet
    $hit = @($r.Findings | Where-Object { $_.Kind -eq 'extra' -and $_.Path -eq 'scripts/rogue.ps1' })
    Assert-DriftSelfTest 'e) 多余源码文件 FAIL 且点名文件' ((-not $r.Ok) -and $hit.Count -eq 1) (Get-FindingDetail $r)

    # f) BOM：内容相同但多了 UTF-8 BOM，必须报 bom 而不是含糊的 content
    $bomCopy = New-InstallCopy 'f-bom'
    $target = Join-Path $bomCopy 'SKILL.md'
    $body = [System.IO.File]::ReadAllBytes($target)
    [System.IO.File]::WriteAllBytes($target, [byte[]]($script:BomBytes + $body))
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $bomCopy -Quiet
    $hit = @($r.Findings | Where-Object { $_.Kind -eq 'bom' -and $_.Path -eq 'SKILL.md' })
    Assert-DriftSelfTest 'f) BOM 能报出（kind=bom）' ((-not $r.Ok) -and $hit.Count -eq 1 -and $r.Findings.Count -eq 1) (Get-FindingDetail $r)

    # g) 以 HEAD 为准：工作区改了、安装仍是 HEAD 字节 -> 必须 PASS
    #    （这正是 scripts/sample-tasks.json 的情形：用户自有未提交改动不该被当成安装漂移）
    $headCopy = New-InstallCopy 'g-head'
    $dirty = Join-Path $repo 'scripts\sample-tasks.json'
    $original = [System.IO.File]::ReadAllBytes($dirty)
    try {
        [System.IO.File]::WriteAllText($dirty, "[{ `"id`": `"demo`", `"intervalMin`": 0 }, { `"id`": `"user-row`" }]`n", $script:Utf8NoBom)
        $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $headCopy -Quiet
        Assert-DriftSelfTest 'g) 工作区脏但安装==HEAD 仍 PASS（以 HEAD 为准）' ($r.Ok) (Get-FindingDetail $r)
    }
    finally {
        [System.IO.File]::WriteAllBytes($dirty, $original)
    }

    # h) 不可读文件：必须 FAIL，且句柄释放后恢复 PASS（证明报红不是永久性噪声）
    $locked = New-InstallCopy 'h-unreadable'
    $handle = [System.IO.File]::Open((Join-Path $locked 'VERSION'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $locked -Quiet
        $hit = @($r.Findings | Where-Object { $_.Kind -eq 'unreadable' -and $_.Path -eq 'VERSION' })
        Assert-DriftSelfTest 'h) 不可读文件 FAIL 且点名文件' ((-not $r.Ok) -and $hit.Count -eq 1) (Get-FindingDetail $r)
    }
    finally {
        $handle.Dispose()
    }
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $locked -Quiet
    Assert-DriftSelfTest 'h2) 句柄释放后恢复 PASS' ($r.Ok) (Get-FindingDetail $r)

    # i) 显式清单（= 受控全集）：清单内的篡改必须报 content，且不产生 extra 噪声
    $manifestPath = Join-Path $Root 'drift-manifest.txt'
    [System.IO.File]::WriteAllText($manifestPath, ((@($seed.Keys) -join "`n") + "`n"), $script:Utf8NoBom)
    $subset = New-InstallCopy 'i-manifest'
    $target = Join-Path $subset 'scripts\patrol-loop.ps1'
    $bytes = [System.IO.File]::ReadAllBytes($target)
    $bytes[0] = $bytes[0] -bxor 0x01
    [System.IO.File]::WriteAllBytes($target, $bytes)
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $subset -ManifestFile $manifestPath -Quiet
    $hit = @($r.Findings | Where-Object { $_.Kind -eq 'content' -and $_.Path -eq 'scripts/patrol-loop.ps1' })
    Assert-DriftSelfTest 'i) 显式受控清单生效（checked 与清单一致）' (($hit.Count -eq 1) -and $r.Findings.Count -eq 1 -and $r.Checked -eq $seed.Count) ("checked=$($r.Checked) " + (Get-FindingDetail $r))

    # j) 排除清单：被排除的文件既不比对也不算多出
    $excludedCopy = New-InstallCopy 'j-exclude'
    $target = Join-Path $excludedCopy 'docs\notes.md'
    [System.IO.File]::WriteAllText($target, "tampered`n", $script:Utf8NoBom)
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $excludedCopy -Quiet -ManifestFile ''
    Assert-DriftSelfTest 'j) -ExcludePath 前的基线：未被排除时 docs/notes.md 必须报红' (-not $r.Ok) (Get-FindingDetail $r)
    $script:ExcludePatterns = @([System.Management.Automation.WildcardPattern]::new('docs/*', [System.Management.Automation.WildcardOptions]::IgnoreCase))
    try {
        $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $excludedCopy -Quiet
        Assert-DriftSelfTest 'j2) -ExcludePath docs/* 后不报该文件且 checked 减一' ($r.Ok -and $r.Checked -eq ($seed.Count - 1) -and $r.Excluded -eq 1) ("checked=$($r.Checked) excluded=$($r.Excluded) " + (Get-FindingDetail $r))
    }
    finally {
        $script:ExcludePatterns = @()
    }

    # k) 换行符差异仍然是红（逐字节口径），但 detail 要说清是 EOL，不是神秘内容漂移
    $crlf = New-InstallCopy 'k-crlf'
    $target = Join-Path $crlf 'SKILL.md'
    $lf = [System.IO.File]::ReadAllText($target, $script:Utf8NoBom)
    [System.IO.File]::WriteAllText($target, ($lf -replace "`r`n", "`n" -replace "`n", "`r`n"), $script:Utf8NoBom)
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $crlf -Quiet
    $eol = @($r.Findings | Where-Object { $_.Kind -eq 'content' -and $_.Path -eq 'SKILL.md' -and $_.Detail -match '换行符' })
    Assert-DriftSelfTest 'k) CRLF/LF 差异 FAIL 且 detail 点明换行符' ((-not $r.Ok) -and $eol.Count -eq 1) (Get-FindingDetail $r)

    # l/m) 版本迁移事故：现有 (d)/(e) 已在「单提交、篡改副本」口径下覆盖 missing / extra 判定，
    #      这两条补的是此前没建模的事故形态 —— 自证仓再往前推提交，HEAD 领先于已安装副本。
    #      不复用 (d)「删一个基线文件」/ (e)「加一个从没受控的 rogue」的构造，避免重复断言。

    # 另一处 codex-home 的已安装副本：停在基线提交，是完整的旧版，不是被删过文件的残缺副本。
    $otherHome = Join-Path $Root 'other-home\skills\patrol-scaffold'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $otherHome) | Out-Null
    Copy-Item -LiteralPath $repo -Destination $otherHome -Recurse -Force
    $otherGit = Join-Path $otherHome '.git'
    if (Test-Path -LiteralPath $otherGit) { Remove-Item -LiteralPath $otherGit -Recurse -Force }

    function Add-SelftestCommit {
        param([string]$Message)
        & git -C $repo -c core.autocrlf=false add -A 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "自证用 git add 失败（$Message）" }
        & git -C $repo -c core.autocrlf=false -c user.name='install-drift-selftest' -c user.email='selftest@example.invalid' commit -q -m $Message 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "自证用 git commit 失败（$Message）" }
    }

    # 提交 2：只新增一个受控文件 —— 旧版副本落后一个提交，缺的正是这个新文件。
    [System.IO.File]::WriteAllText((Join-Path $repo 'scripts\new-worker.ps1'), "Write-Output 'new worker'`n", $script:Utf8NoBom)
    Add-SelftestCommit 'selftest: add new-worker.ps1'

    # l) 已安装 skill 指向另一处 codex-home 的旧版副本：必须 FAIL 且点名缺失的新文件
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $otherHome -Quiet
    $hit = @($r.Findings | Where-Object { $_.Kind -eq 'missing' -and $_.Path -eq 'scripts/new-worker.ps1' })
    Assert-DriftSelfTest 'l) 落后一个提交的旧版副本 FAIL 且点名缺失新文件' ((-not $r.Ok) -and $hit.Count -eq 1 -and $r.Findings.Count -eq 1) (Get-FindingDetail $r)

    # 提交 3：把一个受控脚本改名（旧名从 HEAD 消失、新名进 HEAD），模拟升级时的改名。
    $oldScript = Join-Path $repo 'scripts\patrol-loop.ps1'
    $oldScriptBytes = [System.IO.File]::ReadAllBytes($oldScript)
    [System.IO.File]::WriteAllBytes((Join-Path $repo 'scripts\patrol-loop-v2.ps1'), $oldScriptBytes)
    Remove-Item -LiteralPath $oldScript -Force
    Add-SelftestCommit 'selftest: rename patrol-loop.ps1 to patrol-loop-v2.ps1'

    # m) 新旧两版并存：安装目录 = 新版全套 + 上一版已改名的受控脚本（旧名残留）
    $coexist = New-InstallCopy 'm-coexist'
    [System.IO.File]::WriteAllBytes((Join-Path $coexist 'scripts\patrol-loop.ps1'), $oldScriptBytes)
    $r = Invoke-InstallDriftCheck -RepoRoot $repo -InstalledPath $coexist -Quiet
    $hit = @($r.Findings | Where-Object { $_.Kind -eq 'extra' -and $_.Path -eq 'scripts/patrol-loop.ps1' })
    Assert-DriftSelfTest 'm) 新旧两版并存 FAIL 且点名多出的旧受控文件' ((-not $r.Ok) -and $hit.Count -eq 1 -and $r.Findings.Count -eq 1) (Get-FindingDetail $r)

    return [pscustomobject]@{ Pass = $script:SelfPass; Fail = $script:SelfFail }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
$exitCode = 0
$tmpRoot = $null

try {
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        Write-Host ("RESULT: FAIL — 仓库路径不存在：{0}" -f $RepoRoot)
        exit 2
    }
    $repoCheck = Invoke-GitRaw -Repo $RepoRoot -Arguments @('rev-parse', '--show-toplevel')
    if ($repoCheck.ExitCode -ne 0) {
        Write-Host ("RESULT: FAIL — 不是 git 仓库：{0}" -f $RepoRoot)
        exit 2
    }

    if (-not $NoSelfTest) {
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-install-drift-selftest-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
        $self = Invoke-DriftSelfTest -Root $tmpRoot
        Write-Host ('summary selftest pass={0} fail={1}' -f $self.Pass, $self.Fail)
        if ($self.Fail -gt 0) { $exitCode = 1 }
    }

    if ([string]::IsNullOrWhiteSpace($InstalledPath)) {
        Write-Host '[SKIP] live drift check：未给 -InstalledPath（本机已安装 skill 目录），只跑了自证段'
    }
    else {
        if (-not (Test-Path -LiteralPath $InstalledPath -PathType Container)) {
            Write-Host ("RESULT: FAIL — 安装目录不存在或不是目录：{0}" -f $InstalledPath)
            exit 2
        }
        $installFull = [System.IO.Path]::GetFullPath($InstalledPath).TrimEnd('\', '/')
        $repoFull = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\', '/')
        if ($installFull.Equals($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host 'RESULT: FAIL — -InstalledPath 指向仓库本身；本自检比的是「安装目录 vs 仓库 HEAD」'
            exit 2
        }

        $headShort = (Invoke-GitRaw -Repo $RepoRoot -Arguments @('rev-parse', '--short', 'HEAD')).Out
        $headShort = $script:Utf8NoBom.GetString($headShort).Trim()

        Write-Host ("repo     : {0}" -f $repoFull)
        Write-Host ("head     : {0}" -f $headShort)
        Write-Host ("install  : {0}" -f $installFull)
        Write-Host ("manifest : {0}" -f $(if ($ManifestFile) { $ManifestFile } else { 'HEAD（git ls-tree -r）' }))
        if ($script:ExcludePatterns.Count -gt 0) {
            Write-Host ("exclude  : {0}" -f (($script:ExcludePatterns | ForEach-Object { $_.ToString() }) -join ', '))
        }

        $result = Invoke-InstallDriftCheck -RepoRoot $RepoRoot -InstalledPath $installFull -ManifestFile $ManifestFile
        Write-DriftReport -Result $result -InstalledPath $installFull
        if (-not $result.Ok) { $exitCode = 1 }
    }
}
catch {
    Write-Host ("RESULT: FAIL — {0}" -f $_.Exception.Message)
    exit 2
}
finally {
    if ($tmpRoot) {
        $fullTmp = [System.IO.Path]::GetFullPath($tmpRoot)
        $tempPrefix = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($fullTmp.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $fullTmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($exitCode -eq 0) { Write-Host 'RESULT: PASS' } else { Write-Host 'RESULT: FAIL' }
exit $exitCode
