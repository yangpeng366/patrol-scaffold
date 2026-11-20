#requires -Version 7
<#
    tests/verify-gate-claim-counts.ps1 — 三道闸门「断言数」的机器对拍（离线，无凭据、无网络）。

    背景：三道散文/扫描面闸门（doc-gate / interval-zero / scan-scope）的断言数只写在文档散文里
    （README「N 条断言」、AGENTS「→ summary pass=N」、SKILL 条目），没有任何东西守它。上一轮正是靠人工
    复跑才发现 doc-gate 写的是 19、实测 20（commit 29e39af 才校准）。人工对齐每加一条断言就要重来一次，
    漏一次就又是一份「文档说 19、实测 20」的谎——而且测试全绿。

    本脚本把这件事变成机器对拍，三件事，每件都成对自证：

      1) 实测：子进程真跑三道闸门，解析 `summary pass=N fail=M`；必须 exit 0 / `RESULT: PASS` / fail=0
      2) 对拍：扫入口文档（AGENTS / README / SKILL / docs / references），凡是给这三道闸门写了断言数的
         行、块、句子（`pass=N` 或 `N 条断言`），逐个必须等于本次实测 pass —— 不等就点名 file:line 判红
      3) 自证：陈旧数字必红 / 正确数字必绿 / `#   → summary` 结果行归属它上面那条命令 /
         注释块里的数字归属它下面那条命令 / 兄弟闸门（如 verify-disabled-scheduling）的 13 条断言不许串味

    扫描面与归属规则（都是为了「谁的数算谁的」）：
      - 同一行里只出现一个闸门文件名 → 这行的数字算它的
      - 自描述写法 `doc-gate=pass20` / `interval-zero=pass38` 名字就在数字旁 → 直接归属（不靠上下文）
      - 行首是 `#` 且含 `→`（`#   → summary pass=38 fail=0` 这类结果行）→ 回溯最近的非注释行（命令）
      - 行首是 `#` 但只是说明（`# 口径散文闸门（38 条断言…）`）→ 前探最近的非注释行（命令）
      - 散文行（既无文件名也不在注释块里）→ 不归属，只打 NOTICE（不猜）
      - 一行里出现多个闸门文件名 → 归属不明，打 NOTICE 不算证据（例外见 $orderedSites 的显式顺序表）

    CHANGELOG.md 不参与对拍：它是发布历史，冻结的是当时实测值，不随断言增减改写；仍在 NOTICE 里点名，
    让人一眼看见「这些历史数字不受本闸门保护」。

    用法：
      pwsh -NoProfile -File tests/verify-gate-claim-counts.ps1
    退出码：0 = PASS；1 = 断言数漂移或闸门红；2 = 环境错误（找不到三道闸门之一）。
#>
param(
    # 只看实测、不跑对拍（排查闸门本身时用；CI 与默认都走全量）。
    [switch]$SkipClaimCheck
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:PwshExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($script:PwshExe) -or -not (Test-Path -LiteralPath $script:PwshExe)) { $script:PwshExe = 'pwsh' }
$pass = 0
$fail = 0

function Assert-True {
    param([bool]$Condition, [string]$Label, [string]$Detail)
    if ($Condition) { Write-Host "PASS $Label"; $script:pass++ }
    else {
        Write-Host "FAIL $Label"
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "     $Detail" }
        $script:fail++
    }
}

# 三道被对拍的闸门。Key 是文档里叫它的短名（判红时点名用），Script 是仓内相对路径。
$gates = @(
    [pscustomobject]@{ Key = 'doc-gate'; Script = 'tests/verify-doc-gate-claims.ps1' }
    [pscustomobject]@{ Key = 'interval-zero'; Script = 'tests/verify-interval-zero-claims.ps1' }
    [pscustomobject]@{ Key = 'scan-scope'; Script = 'tests/verify-scan-scope-selfproof.ps1' }
)
$gateByFile = @{}
foreach ($g in $gates) { $gateByFile[(Split-Path -Leaf $g.Script)] = $g.Key }

# 一句话里塞了多个数、没有文件名可归属的写法：显式登记「按出现顺序对应哪道闸门」，不靠猜。
# 这种句子一旦重排数字顺序，本表就要跟着改——宁可判红让人看一眼，也不要默默对错。
$orderedSites = @(
    [pscustomobject]@{
        File   = 'README.md'
        Anchor = '上面三个断言数是本轮实测值'
        Gates  = @('interval-zero', 'doc-gate', 'scan-scope')
    }
)

# 跑一道闸门：子进程执行，stdout/stderr 一并取回，避免 Write-Host 的信息流与退出码在父进程里混成一团。
function Invoke-GateRun {
    param([string]$ScriptRel, [int]$TimeoutSeconds = 300)
    $scriptPath = Join-Path $repoRoot ($ScriptRel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $scriptPath)) { return $null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:PwshExe
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($scriptPath)
    $psi.WorkingDirectory = $repoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try { $p.Kill($true) } catch { }
    }
    $text = (@($outTask.Result, $errTask.Result) -join "`n")
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Text = $text; TimedOut = $timedOut }
}

# 从闸门输出里取最后一条 `summary pass=N fail=M`（多个 summary 时以最后一条收尾行为准）。
function Get-SummaryTuple {
    param([string]$Text)
    $ms = [regex]::Matches($Text, 'summary pass=(\d+) fail=(\d+)')
    if ($ms.Count -eq 0) { return $null }
    $m = $ms[$ms.Count - 1]
    return [pscustomobject]@{ Pass = [int]$m.Groups[1].Value; Fail = [int]$m.Groups[2].Value; SummaryCount = $ms.Count }
}

# 一行里的数字声明：`pass=N` 与 `N 条断言`（后者是中文散文的写法）。
function Get-ClaimValues {
    param([string]$Line)
    $vals = @()
    foreach ($m in [regex]::Matches($Line, 'pass=(\d+)')) {
        $vals += [pscustomobject]@{ Kind = 'pass=N'; Value = [int]$m.Groups[1].Value; Raw = $m.Value }
    }
    foreach ($m in [regex]::Matches($Line, '(\d+)\s*条断言')) {
        $vals += [pscustomobject]@{ Kind = 'N 条断言'; Value = [int]$m.Groups[1].Value; Raw = $m.Value }
    }
    # `summary pass=38 fail=0` 已由上面规则覆盖；`pass=20 / pass=38` 也按出现顺序各算一条。
    return $vals
}

# 最近一条「有 .ps1 文件名」的非注释非空行（跳过段落、代码围栏、注释行）。
function Find-NearestScriptNames {
    param([string[]]$Lines, [int]$Index, [int]$Step)
    for ($d = 1; $d -le 6; $d++) {
        $j = $Index + $Step * $d
        if ($j -lt 0 -or $j -ge $Lines.Count) { return $null }
        $t = $Lines[$j]
        if ($t -match '^\s*$') { continue }
        if ($t -match '^\s*```') { continue }
        if ($t -match '^\s*#') { continue }
        $m = [regex]::Matches($t, '[A-Za-z0-9_.-]+\.ps1')
        if ($m.Count -gt 0) { return @($m | ForEach-Object { $_.Value } | Sort-Object -Unique) }
    }
    return $null
}

# 扫一份文本，返回归属于三道闸门的数字声明 + 归属不明/不相关的行（供 NOTICE）。
function Get-GateClaimsFromText {
    param([string]$Text, [string]$Source)
    $lines = $Text -split "\r?\n"
    $claims = @()
    $ambiguous = @()
    foreach ($site in @($orderedSites | Where-Object { $_.File -eq $Source })) {
        # 显式顺序站点：整行按出现顺序对上注册的闸门列表，行内其它数字（如 `fail=0`）不参与。
        $lineNo = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Contains($site.Anchor)) { $lineNo = $i; break }
        }
        if ($lineNo -lt 0) { continue }
        $vals = @([regex]::Matches($lines[$lineNo], 'pass=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
        for ($k = 0; $k -lt [Math]::Min($vals.Count, $site.Gates.Count); $k++) {
            $claims += [pscustomobject]@{
                Gate = $site.Gates[$k]; Value = $vals[$k]; Kind = "ordered pass=$($vals[$k])"
                Source = $Source; LineNo = $lineNo + 1
            }
        }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNo = $i + 1
        if (@($orderedSites | Where-Object { $_.File -eq $Source -and $line.Contains($_.Anchor) }).Count -gt 0) { continue }
        # 自描述写法（`doc-gate=pass20` / `interval-zero=pass38`）：名字就在数字旁边，不需要靠上下文归属。
        $named = @([regex]::Matches($line, '(doc-gate|interval-zero|scan-scope)=pass(\d+)'))
        if ($named.Count -gt 0) {
            foreach ($m in $named) {
                $claims += [pscustomobject]@{ Gate = $m.Groups[1].Value; Value = [int]$m.Groups[2].Value; Kind = $m.Value; Source = $Source; LineNo = $lineNo }
            }
            continue
        }
        $vals = @(Get-ClaimValues -Line $line)
        if ($vals.Count -eq 0) { continue }
        $names = @([regex]::Matches($line, '[A-Za-z0-9_.-]+\.ps1') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        # 归属优先级：同行唯一文件名 > 结果行回溯上一条命令 > 说明注释前探下一条命令。
        # 必须 @(...) 包一层：函数返回单元素数组时 PowerShell 会退化成字符串，$scope[0] 就成了首个字符。
        $scope = @()
        if ($names.Count -eq 1) { $scope = $names }
        elseif ($names.Count -gt 1) {
            # 只有「提到本阀门 + 别家」才算归属不明；整行都是别家阀门（如 command-adapter 的 45）不归本闸门管，静默跳过。
            if (@($names | Where-Object { $gateByFile[$_] }).Count -gt 0) {
                $ambiguous += [pscustomobject]@{ Source = $Source; LineNo = $lineNo; Why = ('一行提及 {0} 个脚本' -f $names.Count); Text = $line.Trim() }
            }
            continue
        } elseif ($line -match '^\s*#' -and $line -match '→') {
            $scope = @(Find-NearestScriptNames -Lines $lines -Index $i -Step -1)
        } elseif ($line -match '^\s*#') {
            $scope = @(Find-NearestScriptNames -Lines $lines -Index $i -Step 1)
        }
        if ($scope.Count -ne 1) {
            if ($scope.Count -gt 1 -and @($scope | Where-Object { $gateByFile[$_] }).Count -gt 0) {
                $ambiguous += [pscustomobject]@{ Source = $Source; LineNo = $lineNo; Why = '归属到多脚本块'; Text = $line.Trim() }
            }
            continue
        }
        $key = $gateByFile[$scope[0]]
        if ($null -eq $key) { continue }   # 别的闸门（如 verify-disabled-scheduling 的 13 条断言）不归本闸门管
        foreach ($v in $vals) {
            $claims += [pscustomobject]@{ Gate = $key; Value = $v.Value; Kind = $v.Kind; Source = $Source; LineNo = $lineNo }
        }
    }
    return [pscustomobject]@{ Claims = $claims; Ambiguous = $ambiguous }
}

# ---- 1) 实测：三道闸门真跑 ----
$measured = @{}
$envReady = $true
foreach ($g in $gates) {
    $run = Invoke-GateRun -ScriptRel $g.Script
    if ($null -eq $run) {
        $envReady = $false
        Write-Host ('FAIL 环境：找不到闸门脚本 {0}' -f $g.Script)
        continue
    }
    $tail = (@(($run.Text -split "\r?\n") | Where-Object { $_.Trim() -ne '' }) | Select-Object -Last 2) -join ' / '
    $sum = Get-SummaryTuple -Text $run.Text
    Assert-True ($run.ExitCode -eq 0 -and $run.Text -match 'RESULT: PASS') `
        ('1) {0} 实跑绿（exit={1}）' -f $g.Key, $run.ExitCode) $tail
    Assert-True ($null -ne $sum) ('1) {0} 输出里有 summary pass=N fail=M（命中 {1} 条）' -f $g.Key, $(if ($sum) { $sum.SummaryCount } else { 0 })) $tail
    if ($sum) {
        $measured[$g.Key] = $sum.Pass
        Assert-True ($sum.Fail -eq 0) ('1) {0} 实测 fail=0（实得 pass={1} fail={2}）' -f $g.Key, $sum.Pass, $sum.Fail) $tail
        Assert-True ($sum.Pass -gt 0) ('1) {0} 实测断言数 > 0（实得 {1}）' -f $g.Key, $sum.Pass) $tail
    }
}
if (-not $envReady -or $measured.Count -ne $gates.Count) {
    Write-Host ('summary pass={0} fail={1}' -f $pass, ($fail + 1))
    Write-Host 'RESULT: FAIL — 环境错误：三道闸门没跑全'
    exit 2
}

# ---- 2) 对拍：入口文档里的数字 vs 实测 ----
$docFiles = @('AGENTS.md', 'README.md', 'SKILL.md')
foreach ($dir in @('docs', 'references')) {
    $p = Join-Path $repoRoot $dir
    if (Test-Path -LiteralPath $p) {
        $docFiles += @(Get-ChildItem -LiteralPath $p -Filter *.md -File -Recurse |
            ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName) })
    }
}
$docFiles = @($docFiles | Sort-Object -Unique)

$allClaims = @()
$allAmbiguous = @()
if (-not $SkipClaimCheck) {
    foreach ($rel in $docFiles) {
        $p = Join-Path $repoRoot $rel
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $text = [System.IO.File]::ReadAllText($p, $script:Utf8NoBom)
        $hit = Get-GateClaimsFromText -Text $text -Source $rel
        $allClaims += @($hit.Claims)
        $allAmbiguous += @($hit.Ambiguous)
    }

    $totalSites = $allClaims.Count
    Assert-True ($totalSites -ge 10) ('2) 对拍面不是空集：文档里抓到 {0} 处断言数声明' -f $totalSites) `
        (($allClaims | ForEach-Object { '{0}:{1} {2}={3}' -f $_.Source, $_.LineNo, $_.Gate, $_.Value }) -join ' ; ')

    foreach ($g in $gates) {
        $rows = @($allClaims | Where-Object { $_.Gate -eq $g.Key })
        $mismatch = @($rows | Where-Object { $_.Value -ne $measured[$g.Key] })
        $detail = ($mismatch | ForEach-Object { '{0}:{1} 写 {2}={3}（实测 {4}）' -f $_.Source, $_.LineNo, $_.Kind, $_.Value, $measured[$g.Key] }) -join ' ;; '
        Assert-True ($rows.Count -ge 2) ('2) {0} 的断言数在文档里有 ≥2 处声明（实得 {1} 处）' -f $g.Key, $rows.Count) `
            (($rows | ForEach-Object { '{0}:{1}' -f $_.Source, $_.LineNo }) -join ', ')
        Assert-True ($mismatch.Count -eq 0) ('2) {0} 文档断言数 = 实测 pass={1}（{2} 处全对）' -f $g.Key, $measured[$g.Key], $rows.Count) $detail
    }

    if ($allAmbiguous.Count -gt 0) {
        Write-Host ('NOTICE 归属不明的断言数行（{0} 处，不计入对拍）：{1}' -f $allAmbiguous.Count, (($allAmbiguous | ForEach-Object { '{0}:{1}' -f $_.Source, $_.LineNo }) -join ', '))
    }
}

# CHANGELOG 是发布历史，冻结当时实测值，不参与对拍；仍在 NOTICE 里点名，避免有人以为它被保护着。
$changelog = Join-Path $repoRoot 'CHANGELOG.md'
if (-not $SkipClaimCheck -and (Test-Path -LiteralPath $changelog)) {
    $histText = [System.IO.File]::ReadAllText($changelog, $script:Utf8NoBom)
    $hist = @(Get-GateClaimsFromText -Text $histText -Source 'CHANGELOG.md').Claims
    Assert-True ($true) ('2) CHANGELOG.md 不参与对拍（历史冻结），其中历史数字 {0} 处仅供人读' -f $hist.Count)
    if ($hist.Count -gt 0) {
        Write-Host ('NOTICE 不受保护的发布历史数字：{0}' -f (($hist | ForEach-Object { 'CHANGELOG.md:{0} {1}={2}' -f $_.LineNo, $_.Gate, $_.Value }) -join ' ; '))
    }
}

# ---- 3) 自证：陈旧数字必红 / 正确数字必绿 / 归属规则不乱贴 ----
$fixtures = @(
    [pscustomobject]@{
        Id = 'A'; Label = '3) 陈旧数字必红：scan-scope 写 20（实测 19）'
        Text = 'pwsh -NoProfile -File tests/verify-scan-scope-selfproof.ps1   # 20 条断言'
        Source = 'fixture/stale'; ExpectGate = 'scan-scope'; ExpectValue = 20; ExpectRed = $true
    }
    [pscustomobject]@{
        Id = 'B'; Label = '3) 正确数字必绿：同一行写 19（实测 19）'
        Text = 'pwsh -NoProfile -File tests/verify-scan-scope-selfproof.ps1   # 19 条断言'
        Source = 'fixture/ok'; ExpectGate = 'scan-scope'; ExpectValue = 19; ExpectRed = $false
    }
    [pscustomobject]@{
        Id = 'C'; Label = '3) 结果行归属上一条命令：`→ summary pass=18` 挂在 scan-scope 命令后'
        Text = @'
pwsh -NoProfile -File tests/verify-scan-scope-selfproof.ps1
#   → summary pass=18 fail=0 + RESULT: PASS
'@
        Source = 'fixture/result-line'; ExpectGate = 'scan-scope'; ExpectValue = 18; ExpectRed = $true
    }
    [pscustomobject]@{
        Id = 'D'; Label = '3) 说明注释归属下一条命令：`（37 条断言）` 写在 interval-zero 命令前'
        Text = @'
# 口径散文闸门（37 条断言）

pwsh -NoProfile -File tests/verify-interval-zero-claims.ps1
'@
        Source = 'fixture/leading-comment'; ExpectGate = 'interval-zero'; ExpectValue = 37; ExpectRed = $true
    }
    [pscustomobject]@{
        Id = 'E'; Label = '3) 兄弟闸门的数不串味：verify-disabled-scheduling 的 13 条断言不算三道闸门的'
        Text = @'
# 停跑语义门禁：intervalMin 0/空/缺列/负数 = 停跑（13 条断言 + 3 个变异自证）
pwsh -NoProfile -File tests/verify-disabled-scheduling.ps1
'@
        Source = 'fixture/sibling'; ExpectGate = $null; ExpectValue = 0; ExpectRed = $false
    }
    [pscustomobject]@{
        Id = 'F'; Label = '3) 自描述写法也守：`doc-gate=pass21` 自己就带闸门名'
        Text = 'measured  : doc-gate=pass21 / interval-zero=pass38 / scan-scope=pass19'
        Source = 'fixture/named'; ExpectGate = 'doc-gate'; ExpectValue = 21; ExpectRed = $true
    }
)
foreach ($f in $fixtures) {
    $hit = Get-GateClaimsFromText -Text $f.Text -Source $f.Source
    if ($null -eq $f.ExpectGate) {
        Assert-True ($hit.Claims.Count -eq 0) $f.Label (($hit.Claims | ForEach-Object { '{0}={1}' -f $_.Gate, $_.Value }) -join ', ')
        continue
    }
    $got = @($hit.Claims | Where-Object { $_.Gate -eq $f.ExpectGate })
    $ok = ($got.Count -eq 1 -and $got[0].Value -eq $f.ExpectValue)
    Assert-True $ok ('{0}（归属到 {1}={2}）' -f $f.Label, $f.ExpectGate, $f.ExpectValue) `
        (($hit.Claims | ForEach-Object { '{0}={1}' -f $_.Gate, $_.Value }) -join ', ')
    # 判红/判绿成对：拿抓到的数字与实测比对，结论必须与预期一致（自证规则本身不空转）。
    $isRed = ($got.Count -eq 1 -and $got[0].Value -ne $measured[$f.ExpectGate])
    Assert-True ($isRed -eq $f.ExpectRed) ('{0}：与实测比对结论为 {1}（期望 {2}）' -f $f.Id, $(if ($isRed) { '红' } else { '绿' }), $(if ($f.ExpectRed) { '红' } else { '绿' }))
}

Write-Host ('measured  : ' + (($gates | ForEach-Object { '{0}=pass{1}' -f $_.Key, $measured[$_.Key] }) -join ' / '))
Write-Host ('summary pass={0} fail={1}' -f $pass, $fail)
if ($fail -gt 0) { Write-Host 'RESULT: FAIL'; exit 1 }
Write-Host 'RESULT: PASS'
exit 0
