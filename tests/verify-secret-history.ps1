#requires -Version 7
<#
    tests/verify-secret-history.ps1 — 历史密钥盘点（只报告，不失败，不改历史）

    范围：git log -p --all 的新增行（含已删除文件的历史内容）。
    输出：命中的提交（短哈希 + 标题）、文件、规则、掩码值（前 4 字符 + 长度）。
    纪律：命中只轮换密钥 + 收紧读取路径；不重写已推送历史（force-push 后旧对象仍留在
          协作者克隆、镜像和 reflog 里，改写反而制造「已清理」的错觉）。
    用法：pwsh -NoProfile -File tests/verify-secret-history.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$skPrefix = 's' + 'k' + '-'
$awsPrefix = 'AK' + 'IA'
$ghpPrefix = 'gh' + 'p_'
$bearerWord = 'Bea' + 'rer'
$nameTypesafe = 'TYPESAFE_' + 'API_KEY'
$nameAwsSecret = 'AWS_' + 'SECRET' + '(_ACCESS_KEY)?'
$nameGithub = 'GITHUB_' + 'TOKEN'

$rules = @(
    @{ Id = 'provider-token'
       Re = [regex]::new('(?<![A-Za-z0-9_\-])' + [regex]::Escape($skPrefix) + '[A-Za-z0-9_\-]{16,}') }
    @{ Id = 'bearer-token'
       Re = [regex]::new('(?i)' + [regex]::Escape($bearerWord) + '\s+(?<v>[A-Za-z0-9\-\._~\+/]{24,}=*)') }
    @{ Id = 'env-assignment'
       Re = [regex]::new('(?i)(?<![A-Za-z0-9_])(' + $nameTypesafe + '|' + $nameAwsSecret + '|' + $nameGithub + ')\s*=\s*(?<q>["''])(?<v>[^"'']{8,})\k<q>') }
    @{ Id = 'aws-access-key'
       Re = [regex]::new('(?<![A-Z0-9])' + [regex]::Escape($awsPrefix) + '[0-9A-Z]{12,}') }
    @{ Id = 'github-token'
       Re = [regex]::new([regex]::Escape($ghpPrefix) + '[A-Za-z0-9]{20,}') }
)

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

Push-Location $root
try {
    $meta = @(& git log --all --no-color --format='%H%x09%s' 2>&1)
    $metaExit = $LASTEXITCODE
    $patch = @(& git log -p --all --no-color --unified=0 2>&1)
    $patchExit = $LASTEXITCODE
} finally { Pop-Location }

if ($metaExit -ne 0 -or $patchExit -ne 0) {
    Write-Host ('FAIL git log failed (meta={0} patch={1})' -f $metaExit, $patchExit)
    exit 1
}

$subjects = @{}
$commitOrder = [System.Collections.Generic.List[string]]::new()
foreach ($row in $meta) {
    if ($row -match '^([0-9a-f]{40})\t(.*)$') {
        $subjects[$Matches[1]] = $Matches[2]
        $commitOrder.Add($Matches[1])
    }
}

Write-Host ('SECRET-HISTORY scan (report only): commits={0} source=git log -p --all --unified=0' -f $commitOrder.Count)

$hits = [System.Collections.Generic.List[object]]::new()
$commit = '<none>'; $file = '<unknown>'; $added = 0
for ($i = 0; $i -lt $patch.Count; $i++) {
    $line = [string]$patch[$i]
    if ($line -match '^commit ([0-9a-f]{7,40})$') { $commit = $Matches[1]; $file = '<unknown>'; continue }
    if ($line -match '^diff --git a/.+ b/(.+)$') { $file = $Matches[1]; continue }
    if ($line -match '^\+\+\+ (?:b/)?(.+)$') { $file = $Matches[1]; continue }
    if ($line -notmatch '^\+(?!\+\+)') { continue }
    $added++
    $content = $line.Substring(1)
    foreach ($rule in $rules) {
        foreach ($m in $rule.Re.Matches($content)) {
            $val = $m.Value
            if ($m.Groups['v'].Success -and $m.Groups['v'].Value.Length -gt 0) { $val = $m.Groups['v'].Value }
            if (Test-AllowedValue -Value $val) { continue }
            $hits.Add([pscustomobject]@{
                Commit = $commit
                Subject = if ($subjects.ContainsKey($commit)) { $subjects[$commit] } else { '' }
                File = $file
                PatchLine = ($i + 1)
                Rule = $rule.Id
                Value = $val
            })
        }
    }
}

foreach ($h in $hits) {
    $short = if ($h.Commit.Length -ge 7) { $h.Commit.Substring(0, 7) } else { $h.Commit }
    Write-Host ('HIT {0} {1} file={2} patchLine={3} rule={4} value={5}' -f $short, $h.Subject, $h.File, $h.PatchLine, $h.Rule, (Get-Masked -Value $h.Value))
}

$affected = @($hits | ForEach-Object { $_.Commit } | Select-Object -Unique)
Write-Host ('summary commits={0} addedLines={1} hits={2} commitsAffected={3}' -f $commitOrder.Count, $added, $hits.Count, $affected.Count)

if ($hits.Count -eq 0) {
    Write-Host 'advice: 历史未命中；继续保持「密钥只从环境变量/仓库外密钥文件读」。'
} else {
    Write-Host 'advice: 立即轮换上述密钥（视为已泄露），并把读取路径收紧到环境变量或仓库外密钥文件。'
    Write-Host 'advice: 不要改写已推送历史；force-push 不会清除协作者克隆 / 镜像 / reflog 里的旧对象。'
    Write-Host 'advice: 如需收尾，在轮换生效后再评估是否对历史做仓库级清理（属独立动作，不在本脚本范围内）。'
}

exit 0
