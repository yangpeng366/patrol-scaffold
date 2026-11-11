#requires -Version 7
# 离线自测：提示词契约 + 解析器行为。不联网、不调模型、零凭据。
#
# 采用的杂音规则（脚本内固定，测试按此断言）：
#   模型回答中除「动作 / 理由 / 人工介入 / 沉淀」以外的非空行（说明文字、``` 围栏、
#   markdown 列表符号等）一律视为杂音：不计入字段、不导致失败，只记进 JSON 的
#   ignoredLines 供排查；只要三行齐全且合法，解析就成功。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPath = Join-Path $root 'scripts\decide-next-action.ps1'
$promptPath = Join-Path $root 'prompts\decide-next-action.md'
. $scriptPath

$pass = 0; $fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Label)
    if ($Condition) { Write-Host "PASS $Label"; $script:pass++ }
    else { Write-Host "FAIL $Label"; $script:fail++ }
}
function Quote-Arg {
    param([string]$Value)
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

$pwshExe = (Get-Process -Id $PID).Path
$tmp = Join-Path $env:TEMP ("verify-decision-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Invoke-Parser {
    param([string]$Name, [string]$Text)
    $inFile = Join-Path $tmp "$Name.in.txt"
    $outFile = Join-Path $tmp "$Name.json"
    $stdoutFile = Join-Path $tmp "$Name.stdout.txt"
    $stderrFile = Join-Path $tmp "$Name.stderr.txt"
    [System.IO.File]::WriteAllText($inFile, $Text, $utf8)
    $argList = @('-NoProfile', '-File', (Quote-Arg $scriptPath), '-InputFile', (Quote-Arg $inFile), '-OutputFile', (Quote-Arg $outFile))
    $proc = Start-Process -FilePath $pwshExe -ArgumentList $argList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    $json = $null
    if (Test-Path -LiteralPath $outFile) {
        $json = [System.IO.File]::ReadAllText($outFile) | ConvertFrom-Json
    }
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = if (Test-Path -LiteralPath $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile).Trim() } else { '' }
        StdErr   = if (Test-Path -LiteralPath $stderrFile) { [System.IO.File]::ReadAllText($stderrFile).Trim() } else { '' }
        Json     = $json
        JsonPath = $outFile
    }
}

# 样例 1：合规
$good = @'
动作: 在 SKILL.md 的 Files 列表补一行 prompts 用法
理由: 用户要求把新提示词挂到文档里
人工介入: 否
'@

# 样例 2：缺字段（少了 人工介入）
$missing = @'
动作: 补 CHANGELOG 的 Unreleased 段
理由: 漏了人工介入这一行
'@

# 样例 3：多行杂音（说明文字 + 代码围栏包着三行）
$noisy = @'
好的，我按提示词要求回答如下：

```text
动作: 跑 tests/verify-decision-prompt.ps1 确认解析器离线可用
理由: 先证明格式解析不依赖网络与模型
人工介入: 否
```

之所以这样选：仓库目前没有 prompts 目录，先落文件再验证。
'@

# 样例 4（附加）：字段重复，必须报错而不是取其一
$duplicate = @'
动作: 跑自测
动作: 改 README
理由: 两条动作互相冲突
人工介入: 否
'@

Write-Host "== case: good =="
$r1 = Invoke-Parser -Name 'good' -Text $good
Assert-True ($r1.ExitCode -eq 0) "good exits 0 (actual=$($r1.ExitCode))"
Assert-True ($null -ne $r1.Json) 'good wrote json'
Assert-True ($r1.Json.action -eq '在 SKILL.md 的 Files 列表补一行 prompts 用法') 'good action parsed'
Assert-True ($r1.Json.reason -eq '用户要求把新提示词挂到文档里') 'good reason parsed'
Assert-True ($r1.Json.needsHuman -eq $false -and $r1.Json.needsHumanText -eq '否') 'good needsHuman=false'
Assert-True (@($r1.Json.ignoredLines).Count -eq 0) "good has no noise (actual=$(@($r1.Json.ignoredLines).Count))"
Assert-True ($r1.StdOut -match 'needsHuman=False') "good stdout reports the flag (stdout=$($r1.StdOut))"

Write-Host "== case: missing field =="
$r2 = Invoke-Parser -Name 'missing' -Text $missing
Assert-True ($r2.ExitCode -ne 0) "missing exits non-zero (actual=$($r2.ExitCode))"
Assert-True ($r2.ExitCode -eq 2) "missing exits 2 not 1 (actual=$($r2.ExitCode))"
Assert-True ($r2.StdErr -match 'E-MISSING-FIELD:humanFlag') "missing names the missing field (stderr=$($r2.StdErr))"
Assert-True ($r2.StdErr -match '缺字段 人工介入') "missing keeps readable text under redirection (stderr=$($r2.StdErr))"
Assert-True ($null -eq $r2.Json) 'missing writes no json'

Write-Host "== case: multi-line noise =="
$r3 = Invoke-Parser -Name 'noisy' -Text $noisy
Assert-True ($r3.ExitCode -eq 0) "noisy exits 0 (actual=$($r3.ExitCode))"
Assert-True ($r3.Json.action -eq '跑 tests/verify-decision-prompt.ps1 确认解析器离线可用') 'noisy action parsed through fences'
Assert-True ($r3.Json.reason -eq '先证明格式解析不依赖网络与模型') 'noisy reason not polluted by noise'
Assert-True ($r3.Json.needsHuman -eq $false) 'noisy needsHuman=false'
Assert-True (@($r3.Json.ignoredLines).Count -ge 4) "noisy records ignored lines (actual=$(@($r3.Json.ignoredLines).Count))"

Write-Host "== case: duplicate field =="
$r4 = Invoke-Parser -Name 'duplicate' -Text $duplicate
Assert-True ($r4.ExitCode -eq 2) "duplicate exits 2 (actual=$($r4.ExitCode))"
Assert-True ($r4.StdErr -match 'E-DUPLICATE-FIELD:action') "duplicate named (stderr=$($r4.StdErr))"

Write-Host "== case: prompt contract + encoding =="
Assert-True (Test-Path -LiteralPath $promptPath) 'prompt file exists'
$promptText = [System.IO.File]::ReadAllText($promptPath)
Assert-True ($promptText -match '动作:') 'prompt declares 动作'
Assert-True ($promptText -match '理由:') 'prompt declares 理由'
Assert-True ($promptText -match '人工介入:') 'prompt declares 人工介入'
Assert-True ($promptText -match '沉淀: - <做法> — <命令>') 'prompt declares 沉淀 hook'
Assert-True (([System.IO.File]::ReadAllBytes($promptPath))[0] -ne 0xEF) 'prompt no BOM'
Assert-True (([System.IO.File]::ReadAllBytes($scriptPath))[0] -ne 0xEF) 'script no BOM'
Assert-True ($promptText -notmatch '&&') 'prompt stays pwsh-7 friendly'

Write-Host "temp=$tmp"
Write-Host "summary pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
