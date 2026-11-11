#requires -Version 7
<#
.SYNOPSIS
  把模型对 prompts/decide-next-action.md 的回答解析成 JSON。只做格式解析。

.DESCRIPTION
  约定输入（模型回答原文）：
      动作: <一句话>
      理由: <一句话>
      人工介入: 是 | 否
  可选一行：沉淀: - <做法> — <命令>

  解析纪律（不猜）：
    - 三行必须各出现且仅出现一次：缺 -> E-MISSING-FIELD，重复 -> E-DUPLICATE-FIELD，值为空 -> E-EMPTY-FIELD
    - 人工介入 只接受 是/否（兼容 yes/no/true/false 归一化），其它 -> E-BAD-FLAG
    - 其余非空行（说明文字、代码围栏、markdown 装饰）一律记为杂音进 ignoredLines，不参与解析、不报错
    - 本脚本不判断动作是否合理、是否该做——那属于模型与人的判断

  错误输出形如 `E-MISSING-FIELD:humanFlag|缺字段 人工介入`：冒号后是稳定 ASCII 字段 id
  （动作=action / 理由=reason / 人工介入=humanFlag），竖线后是中文说明。重定向到文件或 CI
  管道时中文可能被宿主代码页降级成 `?`，ASCII 前半段始终可 grep。

.PARAMETER InputFile
  模型回答的文本文件（必需）。

.PARAMETER OutputFile
  JSON 落盘路径。省略时写到 %TEMP%\decide-next-action.<时间戳>.json。

.OUTPUTS
  退出码：0 成功；1 输入文件缺失或读写失败；2 回答格式不合规。
#>
[CmdletBinding()]
param(
    [string]$InputFile,
    [string]$OutputFile
)

function ConvertFrom-DecisionAnswer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Source = ''
    )

    $values = [ordered]@{ '动作' = $null; '理由' = $null; '人工介入' = $null }
    $fieldIds = @{ '动作' = 'action'; '理由' = 'reason'; '人工介入' = 'humanFlag' }
    $ignored = [System.Collections.Generic.List[string]]::new()
    $skillNote = $null
    $pattern = '^(?<key>动作|理由|人工介入|沉淀)\s*[:：]\s*(?<value>.*)$'

    foreach ($rawLine in ($Text -split "\r?\n")) {
        $line = $rawLine.Trim()
        if ($line.Length -gt 0 -and $line[0] -eq [char]0xFEFF) { $line = $line.Substring(1).Trim() }
        if ($line -eq '') { continue }
        if ($line.StartsWith('```')) { $ignored.Add($line); continue }

        $clean = ($line -replace '^(?:[-*+>]\s*|\d+[.)]\s*)', '') -replace '\*\*', ''
        $clean = $clean.Trim()

        $m = [regex]::Match($clean, $pattern)
        if (-not $m.Success) { $ignored.Add($line); continue }

        $key = $m.Groups['key'].Value
        $value = $m.Groups['value'].Value.Trim()

        if ($key -eq '沉淀') {
            if ($null -eq $skillNote) { $skillNote = $value } else { $ignored.Add($line) }
            continue
        }
        if ($null -ne $values[$key]) { throw ("E-DUPLICATE-FIELD:{0}|重复字段 {1}" -f $fieldIds[$key], $key) }
        if ($value -eq '') { throw ("E-EMPTY-FIELD:{0}|字段为空 {1}" -f $fieldIds[$key], $key) }
        $values[$key] = $value
    }

    foreach ($key in @('动作', '理由', '人工介入')) {
        if ($null -eq $values[$key]) { throw ("E-MISSING-FIELD:{0}|缺字段 {1}" -f $fieldIds[$key], $key) }
    }

    $needsHuman = switch ($values['人工介入'].ToLowerInvariant()) {
        '是' { $true }
        '否' { $false }
        'yes' { $true }
        'no' { $false }
        'true' { $true }
        'false' { $false }
        default { throw ("E-BAD-FLAG:humanFlag|人工介入 只接受 是/否，收到 {0}" -f $values['人工介入']) }
    }

    [pscustomobject]@{
        action         = $values['动作']
        reason         = $values['理由']
        needsHuman     = [bool]$needsHuman
        needsHumanText = if ($needsHuman) { '是' } else { '否' }
        skillNote      = $skillNote
        ignoredLines   = @($ignored)
        source         = $Source
        parsedAt       = (Get-Date).ToString('o')
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    # 重定向到文件或 CI 管道时，宿主代码页会把中文降级成 '?'；显式钉成 UTF-8，让 stderr 可读。
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [Console]::OutputEncoding = $utf8NoBom
        $OutputEncoding = $utf8NoBom
    }
    catch { }

    if ([string]::IsNullOrWhiteSpace($InputFile)) {
        [Console]::Error.WriteLine('[FAIL] E-NO-INPUT: 需要 -InputFile <模型回答文件>')
        exit 1
    }
    $inPath = [System.IO.Path]::GetFullPath($InputFile)
    if (-not (Test-Path -LiteralPath $inPath -PathType Leaf)) {
        [Console]::Error.WriteLine("[FAIL] E-INPUT-NOT-FOUND: $inPath")
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($OutputFile)) {
        $OutputFile = Join-Path $env:TEMP ("decide-next-action.{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $outPath = [System.IO.Path]::GetFullPath($OutputFile)
    $outDir = Split-Path -Parent $outPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    try {
        $text = [System.IO.File]::ReadAllText($inPath)
        $decision = ConvertFrom-DecisionAnswer -Text $text -Source $inPath
    }
    catch {
        [Console]::Error.WriteLine("[FAIL] $($_.Exception.Message)")
        exit 2
    }

    $json = $decision | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($outPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-Host ("[OK] action={0} needsHuman={1} -> {2}" -f $decision.action, $decision.needsHuman, $outPath)
    exit 0
}
