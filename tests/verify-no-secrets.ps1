#requires -Version 7
<#
    tests/verify-no-secrets.ps1 — 密钥卫生自检（只扫受控文件，不联网，不改文件）

    范围：git ls-files 列出的全部受控文件（SKILL.md / references / scripts / tests / fixtures 全覆盖）。
    判定：任一规则命中即 FAIL，非零退出；占位符与明确的测试假值放行（见 Test-AllowedValue）。
    隐私：命中只输出「前 4 字符 + 总长度」，绝不回显完整密钥。
    用法：pwsh -NoProfile -File tests/verify-no-secrets.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sep = [System.IO.Path]::DirectorySeparatorChar

$pass = 0; $fail = 0; $skipCount = 0
function Assert-True {
    param([bool]$Condition, [string]$Label, [string]$Detail)
    if ($Condition) { Write-Host "PASS $Label"; $script:pass++ }
    else {
        Write-Host "FAIL $Label"
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "     $Detail" }
        $script:fail++
    }
}
function Write-Skip {
    param([string]$Label, [string]$Detail)
    Write-Host "SKIP $Label"
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "     $Detail" }
    $script:skipCount++
}

# ---------------------------------------------------------------------------
# 规则定义
# 高危前缀一律在运行时拼接：本文件自己也在扫描范围内，源码里不能出现 token 形态。
# ---------------------------------------------------------------------------
$skPrefix = 's' + 'k' + '-'
$awsPrefix = 'AK' + 'IA'
$ghpPrefix = 'gh' + 'p_'
$bearerWord = 'Bea' + 'rer'
$nameTypesafe = 'TYPESAFE_' + 'API_KEY'
$nameAwsSecret = 'AWS_' + 'SECRET' + '(_ACCESS_KEY)?'
$nameGithub = 'GITHUB_' + 'TOKEN'
$keyFileRe = 'secrets[\\/]+type' + 'safe\.key'

$rules = @(
    @{ Id = 'provider-token'; Label = 'no provider token literal (s-k prefix + 16 chars)'
       Re = [regex]::new('(?<![A-Za-z0-9_\-])' + [regex]::Escape($skPrefix) + '[A-Za-z0-9_\-]{16,}') }
    @{ Id = 'bearer-token'; Label = 'no bearer-token literal (Bearer + 24 chars)'
       Re = [regex]::new('(?i)' + [regex]::Escape($bearerWord) + '\s+(?<v>[A-Za-z0-9\-\._~\+/]{24,}=*)') }
    @{ Id = 'env-assignment'; Label = 'no literal assignment to a credential variable'
       Re = [regex]::new('(?i)(?<![A-Za-z0-9_])(' + $nameTypesafe + '|' + $nameAwsSecret + '|' + $nameGithub + ')\s*=\s*(?<q>["''])(?<v>[^"'']{8,})\k<q>') }
    @{ Id = 'aws-access-key'; Label = 'no cloud access-key id literal (AK-IA + 12 chars)'
       Re = [regex]::new('(?<![A-Z0-9])' + [regex]::Escape($awsPrefix) + '[0-9A-Z]{12,}') }
    @{ Id = 'github-token'; Label = 'no github token literal (gh-p_ + 20 chars)'
       Re = [regex]::new([regex]::Escape($ghpPrefix) + '[A-Za-z0-9]{20,}') }
)

# ---------------------------------------------------------------------------
# 白名单：只用于「已确认是测试假值 / 文档样例」的精确豁免，必须写 Reason，否则不生效。
# 格式：@{ Path = '相对路径'; Value = '值的精确正则'; Reason = '为什么安全' }
# 例行子（当前无条目，因为占位符已由 Test-AllowedValue 覆盖）：
#   @{ Path = 'tests/verify-xxx.ps1'; Value = '^sk-test-[0-9]{4}$'; Reason = '本地断桩假值，从不发往真实网关' }
# ---------------------------------------------------------------------------
$allowList = @(
)

function Test-AllowListed {
    param([string]$Path, [string]$Value)
    foreach ($e in $allowList) {
        if ($Path -ne $e.Path) { continue }
        if ([string]::IsNullOrWhiteSpace($e.Reason)) { continue }
        if ($Value -match $e.Value) { return $true }
    }
    return $false
}

# 允许的形态：环境变量/表达式引用、尖括号占位符、REPLACE_ME 类标记、纯 x 占位、
# 以及显式的测试假值（test-/fake-/dummy-/demo-/sample- 前缀）。
function Test-AllowedValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '<[^<>]{0,200}>') { return $true }
    if ($Value -match '^[$@]') { return $true }
    if ($Value -match '(?i)REPLACE_?ME|CHANGE_?ME|REDACTED|PLACEHOLDER|DUMMY|FAKE|EXAMPLE|SAMPLE|YOUR_|NOT_?REAL') { return $true }
    if ($Value -match '^[xX]{4,}$') { return $true }
    if ($Value -match '(?i)x{4,}') { return $true }
    if ($Value -match '(?i)^(?:sk-|ghp_)?(?:test|fake|dummy|demo|sample)[-_]') { return $true }
    return $false
}

function Get-Masked {
    param([string]$Value)
    $head = if ($Value.Length -ge 4) { $Value.Substring(0, 4) } else { $Value }
    return ('{0}...(len={1})' -f $head, $Value.Length)
}

function Get-SecretHits {
    param([string]$RelPath, [string[]]$Lines)
    $found = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrEmpty($line)) { continue }
        foreach ($rule in $rules) {
            foreach ($m in $rule.Re.Matches($line)) {
                $val = $m.Value
                if ($m.Groups['v'].Success -and $m.Groups['v'].Value.Length -gt 0) { $val = $m.Groups['v'].Value }
                if (Test-AllowedValue -Value $val) { continue }
                if (Test-AllowListed -Path $RelPath -Value $val) { continue }
                $found.Add([pscustomobject]@{ Path = $RelPath; Line = ($i + 1); Rule = $rule.Id; Value = $val })
            }
        }
    }
    return $found
}

# ---------------------------------------------------------------------------
# 1) 受控文件全量扫描
# ---------------------------------------------------------------------------
Push-Location $root
try {
    $trackedRaw = @(& git ls-files 2>&1)
    $gitExit = $LASTEXITCODE
} finally { Pop-Location }
Assert-True ($gitExit -eq 0) 'git ls-files succeeded' ("exit=$gitExit")
if ($gitExit -ne 0) { Write-Host 'summary pass=0 fail=1 skip=0 hits=0'; exit 1 }

$tracked = @($trackedRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
Assert-True ($tracked.Count -gt 0) ('scope: {0} tracked files' -f $tracked.Count) 'git ls-files returned nothing'

$allHits = [System.Collections.Generic.List[object]]::new()
$scanned = 0; $binary = 0; $totalLines = 0
foreach ($rel in $tracked) {
    $full = $root + $sep + ($rel -replace '/', $sep)
    if (-not (Test-Path -LiteralPath $full)) { Write-Skip ('scan ' + $rel) 'tracked but missing on disk'; continue }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { $binary++; Write-Skip ('scan ' + $rel) 'binary content skipped'; continue }
    $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
    $lines = $text -split "`r?`n"
    $totalLines += $lines.Count
    foreach ($h in (Get-SecretHits -RelPath $rel -Lines $lines)) { $allHits.Add($h) }
    $scanned++
}
Assert-True ($scanned -gt 0) ('scan: {0} files / {1} lines ({2} binary skipped)' -f $scanned, $totalLines, $binary)

foreach ($rule in $rules) {
    $ruleHits = @($allHits | Where-Object { $_.Rule -eq $rule.Id })
    foreach ($h in $ruleHits) {
        Write-Host ('     HIT {0}:{1} [{2}] value={3}' -f $h.Path, $h.Line, $h.Rule, (Get-Masked -Value $h.Value))
    }
    Assert-True ($ruleHits.Count -eq 0) ('rule {0}: {1}' -f $rule.Id, $rule.Label) ('{0} hit(s)' -f $ruleHits.Count)
}

# ---------------------------------------------------------------------------
# 2) 定向断言：两个 JEV verify 脚本必须走环境变量或仓库外密钥文件
# ---------------------------------------------------------------------------
$guarded = @('tests/verify-item-jev-decision.ps1', 'tests/verify-jev-shadow-window.ps1')
$envRe = [regex]::new('\$env:' + [regex]::Escape($nameTypesafe), 'IgnoreCase')
$fileRe = [regex]::new($keyFileRe, 'IgnoreCase')
foreach ($rel in $guarded) {
    $full = $root + $sep + ($rel -replace '/', $sep)
    if (-not (Test-Path -LiteralPath $full)) { Write-Skip ('guard ' + $rel) 'not present in this checkout (.gitignore-local file)'; continue }
    $text = [System.Text.UTF8Encoding]::new($false).GetString([System.IO.File]::ReadAllBytes($full))
    $readsEnv = $envRe.IsMatch($text)
    $readsFile = $fileRe.IsMatch($text)
    Assert-True ($readsEnv -or $readsFile) ('guard {0}: key read from env var or external key file' -f $rel) 'neither env read nor external key-file read found'
    $inline = @(Get-SecretHits -RelPath $rel -Lines ($text -split "`r?`n"))
    foreach ($h in $inline) {
        Write-Host ('     HIT {0}:{1} [{2}] value={3}' -f $h.Path, $h.Line, $h.Rule, (Get-Masked -Value $h.Value))
    }
    Assert-True ($inline.Count -eq 0) ('guard {0}: no inline key literal' -f $rel) ('{0} hit(s)' -f $inline.Count)
}

Write-Host ('summary pass={0} fail={1} skip={2} hits={3}' -f $pass, $fail, $skipCount, $allHits.Count)
if ($fail -gt 0) { exit 1 }
exit 0
