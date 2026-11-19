#requires -Version 7
<#
    tests/verify-scan-scope-selfproof.ps1 — 「扫描面收口」的仓内成对自证（离线，无凭据、无网络）。

    两道口径闸门（tests/verify-doc-gate-claims.ps1 / tests/verify-interval-zero-claims.ps1）都带
    -IncludeLocalExtensions：默认只扫受控文件集（git 跟踪），gitignored 本地扩展默认排除。
    此前这条纪律只有软证据——本机凑巧有 docs/jev-shadow.md，才走到「排除」分支；干净机器（CI）走
    「无可排除」分支。于是同一个提交在本机扫 20/25 份、在 CI 扫 19/24 份，两种口径都没人证明过
    「排除」真的会让漂移文本隐形：排除逻辑写错（把受控文件也排掉、或压根没排）两处都会照样绿。

    本脚本在 %TEMP% 现造一个真 git 仓（受控文件按本仓 git ls-files 复制 + 一次 commit），再放一份
    被 .git/info/exclude 挡住的样本文件，样本里抄着两道闸门各自认得的历史漂移原文，然后成对取证：

      A) 默认跑（不带开关）→ 必须 PASS，且打 NOTICE 点名「跳过 1 份 … local-extension-sample」：
         样本真被 git check-ignore 命中并排除，闸门看不到它
      B) 带 -IncludeLocalExtensions → 必须 FAIL 且点名样本：opt-in 真把扩展拉进扫描面
      C) 把样本 git add -f 提成受控文件后再默认跑 → 必须 FAIL 且点名样本：
         反证 A 的「绿」来自收口，而不是扫描器本身瞎了

    三道闸门各跑 A/B/C；缺任一条都不算证据（只验 A 会放过「排除写过头」，只验 B 会放过「默认没收口」）。
    临时仓每次现造，不读本机状态、不联网、不需要任何 secret，CI 上可真跑。

    用法：
      pwsh -NoProfile -File tests/verify-scan-scope-selfproof.ps1
      pwsh -NoProfile -File tests/verify-scan-scope-selfproof.ps1 -KeepTemp   # 留现场排查
    退出码：0 = PASS；1 = 自证失败；2 = 环境错误（无 git / 源仓不是 git 工作树）。
#>
param(
    # 保留 %TEMP% 里的临时仓，便于排查；默认跑完删除。
    [switch]$KeepTemp
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:pass = 0
$script:fail = 0
$script:tmpRoot = $null

function Assert-True {
    param([bool]$Condition, [string]$Label, [string]$Detail)
    if ($Condition) { Write-Host "PASS $Label"; $script:pass++ }
    else {
        Write-Host "FAIL $Label"
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "     $Detail" }
        $script:fail++
    }
}

# 子进程 tail：闸门脚本 20+ 行输出，失败时只留最后几行做证据。
function Get-GateTail {
    param([pscustomobject]$Run, [int]$Lines = 3)
    $out = @(($Run.Text -split "\r?\n") | Where-Object { $_.Trim() -ne '' })
    if ($out.Count -eq 0) { return ('exit={0}（无输出）' -f $Run.ExitCode) }
    $take = $out | Select-Object -Last $Lines
    return ('exit={0} | {1}' -f $Run.ExitCode, ($take -join ' / '))
}

# 跑一道闸门：子进程执行，stdout/stderr 全量落临时文件再读回，
# 避免 Write-Host 的信息流与退出码在父进程里混到一起。
function Invoke-Gate {
    param([string]$ScriptPath, [switch]$IncludeLocalExtensions)
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw ("闸门脚本不存在：{0}" -f $ScriptPath) }
    $cliArgs = @('-NoProfile', '-File', $ScriptPath)
    if ($IncludeLocalExtensions) { $cliArgs += '-IncludeLocalExtensions' }
    $log = Join-Path $script:tmpRoot ('gate-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
    & $script:PwshExe @cliArgs *> $log
    $code = $LASTEXITCODE
    $text = if (Test-Path -LiteralPath $log) { [System.IO.File]::ReadAllText($log, $script:Utf8NoBom) } else { '' }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $code; Text = $text }
}

# ---- 环境预检（不满足时退 2，不混进断言计数）----
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'RESULT: FAIL — 环境错误：PATH 上没有 git'
    exit 2
}
$insideWorkTree = (& git -C $repoRoot rev-parse --is-inside-work-tree 2>$null)
if ($LASTEXITCODE -ne 0 -or "$insideWorkTree".Trim() -ne 'true') {
    Write-Host ("RESULT: FAIL — 环境错误：不是 git 工作树：{0}" -f $repoRoot)
    exit 2
}
$script:PwshExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($script:PwshExe) -or -not (Test-Path -LiteralPath $script:PwshExe)) { $script:PwshExe = 'pwsh' }

# 样本：两道闸门各自认得的历史漂移原文（逐字取自被修掉的真实位置），装在同一个文件里，
# 于是「排除 / 不排除」的差别在两个方向上都可观测。
$sampleText = @'
# 本地扩展样本（gitignored，不入仓）

本文件由 tests/verify-scan-scope-selfproof.ps1 在临时仓里现造，只用于证明两道口径闸门的扫描面收口
真会排除 gitignored 扩展，而不是闸门本身看不见漂移。

| 写回通道 | 口径 |
|---|---|
| `bitable` | 写回受 `Sync-BitableRoundResult` 的 `-SyncBack` 开关控制 |

`intervalMin` = 0 回退 60 分钟后照常派发。
'@

try {
    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('scan-scope-selfproof-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $repo = Join-Path $script:tmpRoot 'repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    Write-Host ("temp repo : {0}" -f $repo)

    # ---- 1) 造受控副本：按 git ls-files 复制（= CI checkout 看得见的那一批）----
    $tracked = @(& git -C $repoRoot -c core.quotepath=false ls-files)
    $copied = 0
    foreach ($rel in $tracked) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $src = Join-Path $repoRoot ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $repo ($rel -replace '/', '\')
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copied++
    }
    Assert-True ($copied -ge 30) ('1) 受控文件复制进临时仓 {0} 份（源仓 tracked {1} 份）' -f $copied, $tracked.Count)

    & git -C $repo init -q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '临时仓 git init 失败' }
    # 必须 -f：本仓 .gitignore 里有几条规则盖住了「已经跟踪」的路径（如 tests/fixtures/），
    # 裸 add -A 会把它们当未跟踪跳过，临时仓的受控集就比源仓少 2 份，闸门的「排除 N 份」跟着失真。
    & git -C $repo -c core.autocrlf=false add -Af 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '临时仓 git add 失败' }
    & git -C $repo -c core.autocrlf=false -c user.name='scan-scope-selfproof' -c user.email='selftest@example.invalid' commit -q -m 'selfproof baseline' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '临时仓 git commit 失败（缺 user.name/user.email？）' }
    $committed = @(& git -C $repo -c core.quotepath=false ls-files | Where-Object { $_ -ne '' }).Count
    Assert-True ($committed -eq $copied) ('2) 临时仓入库文件数 = 复制数（committed={0} copied={1}）' -f $committed, $copied)

    # ---- 2) 放 gitignored 样本：先让 .git/info/exclude 挡住，再写文件 ----
    $sampleRel = 'docs/local-extension-sample.md'
    $samplePath = Join-Path $repo ($sampleRel -replace '/', '\')
    $excludeFile = Join-Path $repo '.git\info\exclude'
    Add-Content -LiteralPath $excludeFile -Value $sampleRel -Encoding utf8
    [System.IO.File]::WriteAllText($samplePath, $sampleText, $script:Utf8NoBom)

    & git -C $repo check-ignore -q -- $sampleRel
    $isIgnored = ($LASTEXITCODE -eq 0)
    & git -C $repo ls-files --error-unmatch -- $sampleRel 2>$null | Out-Null
    $isTrackedSample = ($LASTEXITCODE -eq 0)
    Assert-True (Test-Path -LiteralPath $samplePath) '3) 样本已落在临时仓 docs/local-extension-sample.md'
    Assert-True ($isIgnored -and -not $isTrackedSample) `
        ('3) 样本确实是 gitignored 本地扩展（check-ignore={0} tracked={1}）' -f $isIgnored, $isTrackedSample)

    $gates = @(
        @{ Key = 'doc-gate'; Script = 'tests\verify-doc-gate-claims.ps1' }
        @{ Key = 'interval-zero'; Script = 'tests\verify-interval-zero-claims.ps1' }
    )
    foreach ($g in $gates) {
        $p = Join-Path $repo $g.Script
        Assert-True (Test-Path -LiteralPath $p) ('3) 临时仓里有闸门副本 {0}' -f $g.Script)

        # ---- A) 默认跑：样本被排除 → 必绿，且 NOTICE 点名它 ----
        $a = Invoke-Gate -ScriptPath $p
        Assert-True ($a.ExitCode -eq 0 -and $a.Text -match 'RESULT: PASS') `
            ('A) {0} 默认跑必绿（样本被排除）' -f $g.Key) (Get-GateTail $a)
        Assert-True ($a.Text -match 'NOTICE' -and $a.Text -match '跳过 1 份' -and $a.Text -match 'local-extension-sample') `
            ('A) {0} 默认跑打出 NOTICE 并点名被排除的样本' -f $g.Key) (Get-GateTail $a 5)

        # ---- B) opt-in：样本进面 → 必红，且判红处点名它 ----
        $b = Invoke-Gate -ScriptPath $p -IncludeLocalExtensions
        Assert-True ($b.ExitCode -eq 1 -and $b.Text -match 'RESULT: FAIL') `
            ('B) {0} -IncludeLocalExtensions 必红（opt-in 真把扩展拉进扫描面）' -f $g.Key) (Get-GateTail $b)
        Assert-True ($b.Text -match 'FAIL 2\)' -and $b.Text -match 'local-extension-sample') `
            ('B) {0} 判红落在「文案回流」这条断言上，并点名样本' -f $g.Key) (Get-GateTail $b 5)
    }

    # ---- 3) 反证：同一份漂移文本改成受控文件后，默认跑必红（绿来自收口，不是扫描器瞎）----
    & git -C $repo -c core.autocrlf=false add -f -- $sampleRel 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '样本提升为受控文件失败（git add -f）' }
    & git -C $repo -c core.autocrlf=false -c user.name='scan-scope-selfproof' -c user.email='selftest@example.invalid' commit -q -m 'promote sample' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '样本提升为受控文件失败（git commit）' }
    & git -C $repo check-ignore -q -- $sampleRel
    $stillIgnored = ($LASTEXITCODE -eq 0)
    Assert-True (-not $stillIgnored) 'C) 样本提为受控后不再被 git check-ignore 命中（排除面确实变窄）'

    foreach ($g in $gates) {
        $c = Invoke-Gate -ScriptPath (Join-Path $repo $g.Script)
        Assert-True ($c.ExitCode -eq 1 -and $c.Text -match 'RESULT: FAIL') `
            ('C) {0} 同一份漂移文本改成受控后默认跑必红（反证 A 的绿不是扫描器瞎）' -f $g.Key) (Get-GateTail $c)
        Assert-True (-not ($c.Text -match 'NOTICE')) `
            ('C) {0} 无 gitignored 扩展时不再打 NOTICE（走「无可排除」分支）' -f $g.Key) (Get-GateTail $c 5)
    }
} catch {
    $script:fail++
    Write-Host ('FAIL exception: {0}' -f $_.Exception.Message)
} finally {
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        if ($KeepTemp) { Write-Host ("kept temp  : {0}" -f $script:tmpRoot) }
        else { Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ('summary pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Host 'RESULT: FAIL'; exit 1 }
Write-Host 'RESULT: PASS'
exit 0
