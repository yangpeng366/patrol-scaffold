#requires -Version 7
<#
    scripts/sync-install.ps1 — 把仓库 HEAD 的受控文件按字节写进已安装 skill 目录（装/升安装用，只写不删）

    为什么要有这个脚本：`docs/releasing.md` §4 已承认「升级时不能整目录覆盖，只能逐文件用 HEAD 字节覆盖」，
    但那条路一直是手工的——0.2.0 之后本机就真出现过「补 18 个缺文件、覆盖 48 个漂移文件」的一次操作，
    而且换行符/编码一错（`core.autocrlf=true` 下 `git archive` 取出来是 CRLF）就会一次性变成几十条
    `content … 仅换行符不同`。本脚本把这一步变成一条幂等命令：

      - 基准是 **HEAD blob**（`git ls-tree -r HEAD` 的普通文件），**不是工作区字节**——理由与
        `tests/verify-install-drift.ps1` 同源：`scripts/sample-tasks.json` 之类的用户自有未提交改动
        不该被当成安装内容写进 skill 目录。
      - 只在字节不同/文件缺失时写；写入用原始 blob 字节，不做文本解码，因此不会引入 BOM 或改换行符。
      - **只写不删**：运行时产物（`state/`、`downloads/`、`memory/`、`reports/`、`*.log`、`notify.log`、
        `patrol-state.json`、`SHA256SUMS.txt` 等）既不在受控集内，也会被显式拒写；多出的本地扩展
        （如 `tests/verify-bitable-adapter.ps1`）只留给 drift 自检报 `extra`，删不删由人决定。
      - 撞到「该是文件的位置是个目录」不静默跳过：点名 + `exit 1`，交给人看一眼再删。

    用法：
      # 1) 看会写哪些（不落盘）
      pwsh -NoProfile -File scripts/sync-install.ps1 -InstalledPath <skill-dir> -DryRun

      # 2) 落地
      pwsh -NoProfile -File scripts/sync-install.ps1 -InstalledPath <skill-dir>

      # 3) 复核（本脚本不自己判 PASS；判 PASS 的是那道闸门）
      pwsh -NoProfile -File tests/verify-install-drift.ps1 -RepoRoot <repo> -InstalledPath <skill-dir>

    退出码：0 = 同步完成（或 dry-run 只列计划）；1 = 有受控路径写不进去（如被目录占位）；
            2 = 用法/环境错误（缺 -InstalledPath、RepoRoot 不是 git 仓、安装目录不存在）。

    运行环境：仅 PowerShell 7（pwsh）+ git。源码 UTF-8 无 BOM。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$InstalledPath = '',
    # 只打印计划，不写任何文件。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# 拒写清单：与 tests/verify-install-drift.ps1 的 RuntimePatterns / .gitignore 同源，
# 避免「受控集算错时把运行态覆盖掉」这类不可逆事故。
$script:RuntimePatterns = @(
    '^\.git(/|$)',
    '^(downloads|memory|state|reports|scripts/downloads|scripts/memory)(/|$)',
    '^jev-shadow-hooks(/|$)',
    '(^|/)patrol-state\.json$',
    '(^|/)command-mirror\.json$',
    '^SHA256SUMS\.txt$',
    '\.(log|tmp|temp|zip|7z|sha256|pyc|orig|bak|swp)$',
    '(^|/)__pycache__(/|$)'
)

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

function Test-RuntimePath {
    param([string]$Rel)
    foreach ($pattern in $script:RuntimePatterns) {
        if ([regex]::IsMatch($Rel, $pattern, 'IgnoreCase')) { return $true }
    }
    return $false
}

# git 必须走原生进程：blob 是二进制，经过 PowerShell 文本管道会被重编码（BOM / CRLF 都会变）
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

function Get-ControlledPaths {
    param([string]$Repo)
    $result = Invoke-GitRaw -Repo $Repo -Arguments @('ls-tree', '-r', '-z', 'HEAD')
    if ($result.ExitCode -ne 0) {
        throw ("git ls-tree HEAD 失败（exit={0}）：{1}" -f $result.ExitCode, $result.Err.Trim())
    }
    $text = $script:Utf8NoBom.GetString($result.Out)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($record in ($text -split "`0")) {
        if ($record -eq '') { continue }
        $meta, $path = $record -split "`t", 2
        if ([string]::IsNullOrEmpty($path)) { continue }
        $parts = $meta -split ' '
        if ($parts.Count -lt 2) { continue }
        if ($parts[1] -ne 'blob') { continue }
        # 符号链接（120000）在 Windows 上不是「一批可写字节」，跳过并单独计数
        if ($parts[0] -eq '120000') { continue }
        $rel = ConvertTo-RelativeKey $path
        if ($rel -eq '' -or $rel -match '(^|/)\.\.(/|$)' -or $rel -match '^[A-Za-z]:') { continue }
        $paths.Add($rel)
    }
    return $paths.ToArray()
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
try {
    if ([string]::IsNullOrWhiteSpace($InstalledPath)) {
        Write-Host 'RESULT: FAIL — 缺少 -InstalledPath（已安装 skill 目录）；本脚本只写已存在目录，不替你建整棵树'
        exit 2
    }
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        Write-Host ("RESULT: FAIL — 仓库路径不存在：{0}" -f $RepoRoot)
        exit 2
    }
    $repoCheck = Invoke-GitRaw -Repo $RepoRoot -Arguments @('rev-parse', '--show-toplevel')
    if ($repoCheck.ExitCode -ne 0) {
        Write-Host ("RESULT: FAIL — 不是 git 仓库：{0}（受控集来自 HEAD blob）" -f $RepoRoot)
        exit 2
    }
    if (-not (Test-Path -LiteralPath $InstalledPath -PathType Container)) {
        Write-Host ("RESULT: FAIL — 安装目录不存在或不是目录：{0}" -f $InstalledPath)
        Write-Host '提示：首次安装用发布归档解出来的目录（docs/releasing.md §3），本脚本只做「已装目录 → HEAD」的同步'
        exit 2
    }

    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $installFull = [System.IO.Path]::GetFullPath($InstalledPath).TrimEnd('\', '/')
    if ($installFull.Equals($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host 'RESULT: FAIL — -InstalledPath 指向仓库本身；同步会把运行时产物与仓库混成一团'
        exit 2
    }

    $headShort = $script:Utf8NoBom.GetString((Invoke-GitRaw -Repo $RepoRoot -Arguments @('rev-parse', '--short', 'HEAD')).Out).Trim()
    $paths = @(Get-ControlledPaths -Repo $RepoRoot)

    Write-Host ("repo     : {0}" -f $repoFull)
    Write-Host ("head     : {0}" -f $headShort)
    Write-Host ("install  : {0}" -f $installFull)
    Write-Host ("mode     : {0}" -f $(if ($DryRun) { 'dry-run（不写文件）' } else { 'apply（按 HEAD 字节写入）' }))

    $unchanged = 0
    $written = 0
    $planned = 0
    $blocked = 0
    $refused = 0

    foreach ($rel in $paths) {
        if (Test-RuntimePath -Rel $rel) {
            $refused++
            Write-Host ("[refuse]   {0}  运行时/产物路径不进受控集，拒写（HEAD 里本不该有；请检查 gitignore 是否被绕过）" -f $rel)
            continue
        }

        $full = Join-Path $installFull ($rel -replace '/', '\')

        if ([System.IO.Directory]::Exists($full)) {
            $blocked++
            Write-Host ("[blocked]  {0}  该是文件的位置是个目录；本脚本不删目录，请人工确认后删除" -f $rel)
            continue
        }

        $headResult = Invoke-GitRaw -Repo $RepoRoot -Arguments @('cat-file', 'blob', "HEAD:$rel")
        if ($headResult.ExitCode -ne 0) {
            throw ("取 HEAD:{0} 失败（exit={1}）：{2}" -f $rel, $headResult.ExitCode, $headResult.Err.Trim())
        }
        $headBytes = $headResult.Out

        if ([System.IO.File]::Exists($full)) {
            $installedBytes = [System.IO.File]::ReadAllBytes($full)
            if ((Get-Sha256Hex -Bytes $headBytes) -eq (Get-Sha256Hex -Bytes $installedBytes)) { $unchanged++; continue }
        }

        if ($DryRun) {
            $planned++
            Write-Host ("[would-write] {0}  bytes={1}" -f $rel, $headBytes.Length)
            continue
        }

        $parent = Split-Path -Parent $full
        if (-not [System.IO.Directory]::Exists($parent)) {
            [void][System.IO.Directory]::CreateDirectory($parent)
        }
        [System.IO.File]::WriteAllBytes($full, $headBytes)
        $written++
        Write-Host ("[write]    {0}  bytes={1}" -f $rel, $headBytes.Length)
    }

    Write-Host ("summary controlled={0} unchanged={1} written={2} planned={3} blocked={4} refused={5}" -f `
            $paths.Count, $unchanged, $written, $planned, $blocked, $refused)

    if ($blocked -gt 0 -or $refused -gt 0) {
        Write-Host 'RESULT: FAIL'
        exit 1
    }

    if ($DryRun) {
        Write-Host ("提示：以上 {0} 个文件是待写清单；去掉 -DryRun 才会落盘" -f $planned)
    }
    elseif ($written -gt 0) {
        Write-Host ("提示：已写 {0} 个文件；请跑 tests/verify-install-drift.ps1 -RepoRoot {1} -InstalledPath {2} 复核" -f $written, $repoFull, $installFull)
    }
    else {
        Write-Host '提示：安装目录已与 HEAD 逐字节一致，无需写入'
    }
    Write-Host 'RESULT: PASS'
    exit 0
}
catch {
    Write-Host ("RESULT: FAIL — {0}" -f $_.Exception.Message)
    exit 2
}
