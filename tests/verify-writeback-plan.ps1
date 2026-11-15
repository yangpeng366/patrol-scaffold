#requires -Version 7
<#
    tests/verify-writeback-plan.ps1 — 回写层的离线门禁（零凭据、零网络）

    被测对象：scripts/patrol-writeback.ps1 —— 巡检 digest -> 回写计划（preview-first）
    + 幂等键 + 只记成功写入的账本。

    为什么要有这道闸门：「回写」是整条链路里唯一会改远端状态的层，一旦幂等性出错，
    重试就会把别人手改的字段覆盖回去，而且**看不出来**（远端只显示最终值）。所以这里
    不测「能不能连上飞书」，只测四类会让回写出事的行为：

      1. 默认档必须零写入：不建账本、不调写手、不改 digest / state（逐字节只读）。
      2. 幂等键必须确定性且分得开：同一 digest 重放同键；stamp / provider / target /
         内容任一变化都必须换键，不能混成同一行。
      3. 重放与内容去重都要真的不写：同 digest 二次 apply -> replay；换 stamp 但内容
         一字未变 -> unchanged；两种情况写手调用次数都必须为 0。
      4. 失败面不许假装成功：写手报失败 / 输出不是 JSON / 漏报某行 -> exit 1，失败行
         不入账（可原样重试），成功行照常入账；账本损坏 -> exit 2 fail-closed。

    全部用例在 %TEMP% 现造 digest / state / ledger / 写手替身，跑完 finally 删除。写手替身不放进
    仓内 fixtures：`tests/fixtures/` 在 .gitignore 里（本地真实样本目录，不入仓），替身由本脚本在
    %TEMP% 生成，因此 CI 上这条门禁同样自包含。

    退出码：0 = 全过；1 = 有用例失败。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:Pass = 0
$script:Fail = 0
$utf8 = [System.Text.UTF8Encoding]::new($false)
$scriptPath = Join-Path $RepoRoot 'scripts\patrol-writeback.ps1'
$writerPath = ''

function Assert-Case {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:Pass++
        Write-Host ("[PASS] {0}{1}" -f $Name, $(if ($Detail) { "  $Detail" } else { '' }))
    }
    else {
        $script:Fail++
        Write-Host ("[FAIL] {0}{1}" -f $Name, $(if ($Detail) { "  $Detail" } else { '' }))
    }
}

function Invoke-Writeback {
    param([string[]]$WbArgs)
    $out = & pwsh -NoProfile -File $scriptPath @WbArgs 2>&1
    $code = $LASTEXITCODE
    $text = (@($out) | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{ ExitCode = $code; Text = $text }
}

function New-DigestFile {
    param(
        [string]$Path,
        [string]$Stamp,
        [string]$Method = 'bitable',
        $Items
    )
    $doc = [ordered]@{
        stamp      = $Stamp
        method     = $Method
        dryRun     = $false
        totalItems = @($Items).Count
        dueCount   = @($Items).Count
        completed  = @($Items).Count
        failed     = 0
        items      = @($Items)
    }
    [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 6), $utf8)
}

function New-Row {
    param([string]$Id, [string]$Stage, [string]$Achievement, [string]$NextStep = '')
    $o = [ordered]@{
        id           = $Id
        title        = "t-$Id"
        priority     = 'P1'
        intervalMin  = 60
        currentStage = $Stage
        achievement  = $Achievement
    }
    if ($NextStep) { $o['nextStep'] = $NextStep }
    return [pscustomobject]$o
}

function Get-PlanDoc {
    param([string]$Path)
    return ([System.IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json)
}

function Get-PlanKeys {
    param([string]$Path)
    $doc = Get-PlanDoc $Path
    $map = @{}
    foreach ($i in @($doc.items)) { $map[[string]$i.id] = [string]$i.idempotencyKey }
    return $map
}

function Get-LedgerKeys {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $doc = [System.IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json
    return @(@($doc.entries) | ForEach-Object { [string]$_.key })
}

function Get-FileHashHex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Reset-WriterEnv {
    $env:FAKE_WRITER_FAIL_IDS = ''
    $env:FAKE_WRITER_GARBAGE = ''
    $env:FAKE_WRITER_DROP = ''
}

$root = Join-Path $env:TEMP ('patrol-writeback-test-{0}' -f ([guid]::NewGuid().ToString('n')))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$savedEnv = @{
    FAKE_WRITER_RECORD   = $env:FAKE_WRITER_RECORD
    FAKE_WRITER_FAIL_IDS = $env:FAKE_WRITER_FAIL_IDS
    FAKE_WRITER_GARBAGE  = $env:FAKE_WRITER_GARBAGE
    FAKE_WRITER_DROP     = $env:FAKE_WRITER_DROP
}

try {
    $ledger = Join-Path $root 'state\writeback-ledger.json'
    $state = Join-Path $root 'state\patrol-state.json'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'state') | Out-Null
    $plan = Join-Path $root 'plan.json'
    $record = Join-Path $root 'writer-record.txt'
    $writerPath = Join-Path $root 'fake-writer.ps1'
    # 写手替身：只认 -PlanFile，其余行为由环境变量注入（回写层只给写手传 -PlanFile）
    $writerSource = @'
#requires -Version 7
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PlanFile)
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
function Split-Ids([string]$Text) {
    $out = @()
    foreach ($token in ($Text -split ',')) { $t = $token.Trim(); if ($t) { $out += $t } }
    return $out
}
if (-not [string]::IsNullOrWhiteSpace($env:FAKE_WRITER_GARBAGE)) { Write-Output 'not-a-json-at-all'; exit 0 }
if (-not (Test-Path -LiteralPath $PlanFile -PathType Leaf)) { exit 2 }
$planObj = [System.IO.File]::ReadAllText($PlanFile, $utf8) | ConvertFrom-Json
$failIds = Split-Ids $env:FAKE_WRITER_FAIL_IDS
$dropIds = Split-Ids $env:FAKE_WRITER_DROP
$results = @()
foreach ($row in @($planObj.items)) {
    $id = [string]$row.id
    if ($env:FAKE_WRITER_RECORD) {
        Add-Content -LiteralPath $env:FAKE_WRITER_RECORD -Value ("{0}`t{1}`t{2}" -f $id, [string]$row.idempotencyKey, [string]$planObj.stamp) -Encoding utf8NoBOM
    }
    if ($dropIds -contains $id) { continue }
    $isFail = $failIds -contains $id
    $results += [ordered]@{ id = $id; ok = (-not $isFail); error = if ($isFail) { 'fixture-injected-failure' } else { '' } }
}
Write-Output ([ordered]@{ results = $results } | ConvertTo-Json -Depth 6 -Compress)
exit 0
'@
    [System.IO.File]::WriteAllText($writerPath, $writerSource, $utf8)
    Reset-WriterEnv
    $env:FAKE_WRITER_RECORD = $record

    # state 里补 nextStep / threadId：验证「digest 没有就退到 state」的取值口径
    [System.IO.File]::WriteAllText($state, (@(
        [ordered]@{ id = 'a'; nextStep = 'next-from-state'; threadId = 'thread-a'; currentStage = 'stale'; achievement = 'stale'; lastRun = '2026-11-01T00:00:00.0000000+08:00' }
        [ordered]@{ id = 'b'; nextStep = 'next-b'; threadId = $null; currentStage = 'stale'; achievement = 'stale'; lastRun = '2026-11-01T00:00:00.0000000+08:00' }
    ) | ConvertTo-Json -Depth 6 -AsArray), $utf8)

    $digest1 = Join-Path $root 'digest-1.json'
    New-DigestFile -Path $digest1 -Stamp '20261115-090000' -Items @(
        (New-Row -Id 'a' -Stage '完成' -Achievement '本轮推进 A')
        (New-Row -Id 'b' -Stage '进行中' -Achievement '本轮推进 B')
        (New-Row -Id 'c' -Stage '完成' -Achievement '本轮推进 C' -NextStep 'digest 自带的下一步')
        (New-Row -Id 'blank' -Stage '' -Achievement '')
    )
    # 一行无 id：不能被当成合法行，也不能让整批中止
    $d1 = [System.IO.File]::ReadAllText($digest1, $utf8) | ConvertFrom-Json
    $d1.items = @($d1.items) + @([pscustomobject]@{ title = 'no-id-row' })
    [System.IO.File]::WriteAllText($digest1, ($d1 | ConvertTo-Json -Depth 6), $utf8)

    $digestHash = Get-FileHashHex $digest1
    $stateHash = Get-FileHashHex $state

    # ---- 1) 默认档：只出计划，零写入 ----
    $r = Invoke-Writeback @('-DigestPath', $digest1, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan)
    Assert-Case '1) preview 退出码 0' ($r.ExitCode -eq 0) "exit=$($r.ExitCode)"
    Assert-Case '1) preview 不建账本文件' (-not (Test-Path -LiteralPath $ledger))
    Assert-Case '1) preview 不调用写手（无记录文件）' (-not (Test-Path -LiteralPath $record))
    Assert-Case '1) preview 逐字节不改 digest / state' ((Get-FileHashHex $digest1) -eq $digestHash -and (Get-FileHashHex $state) -eq $stateHash)
    Assert-Case '1) preview 打印 apply/replay/unchanged 计数' ($r.Text -match 'apply=3' -and $r.Text -match 'replay=0' -and $r.Text -match 'unchanged=0')
    Assert-Case '1) preview 明确声明零远端写入' ($r.Text -match '零远端写入')
    $doc = Get-PlanDoc $plan
    Assert-Case '1) plan.mode=preview' ([string]$doc.mode -eq 'preview')
    Assert-Case '1) plan 里 no-id 行标 noid、空字段行标 empty' (
        (@($doc.items | Where-Object { $_.status -eq 'noid' })).Count -eq 1 -and
        (@($doc.items | Where-Object { $_.id -eq 'blank' -and $_.status -eq 'empty' })).Count -eq 1)
    $planA = @($doc.items | Where-Object { $_.id -eq 'a' })[0]
    $planC = @($doc.items | Where-Object { $_.id -eq 'c' })[0]
    Assert-Case '1) threadId 从 state 补齐、currentStage 取 digest' (
        (@($planA.fields) -contains 'threadId') -and (@($planA.fields) -contains 'currentStage') -and
        ([string]$planA.payload.threadId -eq 'thread-a') -and
        ([string]$planA.payload.currentStage -eq '完成'))
    Assert-Case '1) nextStep 只取 digest 自带的，不凭空造' (
        (-not (@($planA.fields) -contains 'nextStep')) -and
        ([string]$planC.payload.nextStep -eq 'digest 自带的下一步'))

    # ---- 2) 幂等键：确定性 ----
    $keys1 = Get-PlanKeys $plan
    $r = Invoke-Writeback @('-DigestPath', $digest1, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan)
    $keys2 = Get-PlanKeys $plan
    Assert-Case '2) 同一 digest 两次 preview 同键' ($keys1['a'] -eq $keys2['a'] -and $keys1['b'] -eq $keys2['b']) "key=$($keys1['a'].Substring(0,12))…"
    Assert-Case '2) 键是 64 位小写十六进制' ($keys1['a'] -match '^[0-9a-f]{64}$')
    Assert-Case '2) 不同行不同键' ($keys1['a'] -ne $keys1['b'])

    # ---- 3) 幂等键：敏感性（stamp / provider / target / 内容）----
    $digest2 = Join-Path $root 'digest-2.json'
    New-DigestFile -Path $digest2 -Stamp '20261115-090000' -Items @(
        (New-Row -Id 'a' -Stage '完成' -Achievement '本轮推进 A（改了内容）')
        (New-Row -Id 'b' -Stage '进行中' -Achievement '本轮推进 B')
    )
    $r = Invoke-Writeback @('-DigestPath', $digest2, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan)
    $keysContent = Get-PlanKeys $plan
    Assert-Case '3) 内容变化换键' ($keysContent['a'] -ne $keys1['a'])
    Assert-Case '3) 同内容同键（state 补齐的字段不引入抖动）' ($keysContent['b'] -eq $keys1['b'])

    $digest3 = Join-Path $root 'digest-3.json'
    New-DigestFile -Path $digest3 -Stamp '20261115-100000' -Items @(
        (New-Row -Id 'b' -Stage '进行中' -Achievement '本轮推进 B')
    )
    $r = Invoke-Writeback @('-DigestPath', $digest3, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan)
    Assert-Case '3) 换 stamp 换键' ((Get-PlanKeys $plan)['b'] -ne $keys1['b'])

    $r = Invoke-Writeback @('-DigestPath', $digest3, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-Provider', 'csv-file', '-PlanFile', $plan)
    Assert-Case '3) 换 provider 换键' ((Get-PlanKeys $plan)['b'] -ne $keys1['b'])
    $r = Invoke-Writeback @('-DigestPath', $digest3, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/other-table', '-PlanFile', $plan)
    Assert-Case '3) 换 target 换键' ((Get-PlanKeys $plan)['b'] -ne $keys1['b'])

    # ---- 4) apply：真写 + 入账 ----
    $r = Invoke-Writeback @('-DigestPath', $digest1, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan, '-Apply', '-WriterScript', $writerPath)
    Assert-Case '4) apply 退出码 0' ($r.ExitCode -eq 0) "exit=$($r.ExitCode)"
    $lines = @(Get-Content -LiteralPath $record)
    Assert-Case '4) 写手只收到 3 行（no-id / 空字段行不写）' ($lines.Count -eq 3) "lines=$($lines.Count)"
    $ledgerKeys = Get-LedgerKeys $ledger
    Assert-Case '4) 账本记 3 条' ($ledgerKeys.Count -eq 3) "entries=$($ledgerKeys.Count)"
    $ledgerDoc = [System.IO.File]::ReadAllText($ledger, $utf8) | ConvertFrom-Json
    $entryA = @($ledgerDoc.entries | Where-Object { $_.itemId -eq 'a' })[0]
    Assert-Case '4) 账本条目含键/内容哈希/时间/目标/写手' (
        ([string]$entryA.key).Length -eq 64 -and ([string]$entryA.payloadSha256).Length -eq 64 -and
        -not [string]::IsNullOrWhiteSpace([string]$entryA.appliedAt) -and
        [string]$entryA.target -eq 'base/table' -and [string]$entryA.writer -like '*fake-writer.ps1')
    $docApply = Get-PlanDoc $plan
    Assert-Case '4) apply 的 plan 标 mode=apply 且带逐行 result' (
        [string]$docApply.mode -eq 'apply' -and (@($docApply.items | Where-Object { $_.result -and $_.result.ok })).Count -eq 3)

    # ---- 5) 重放同一 digest：必须一行不写 ----
    $before = @(Get-Content -LiteralPath $record).Count
    $r = Invoke-Writeback @('-DigestPath', $digest1, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan, '-Apply', '-WriterScript', $writerPath)
    Assert-Case '5) 重放 apply=0 / replay=3 且退出码 0' ($r.ExitCode -eq 0 -and $r.Text -match 'apply=0' -and $r.Text -match 'replay=3') "exit=$($r.ExitCode)"
    Assert-Case '5) 重放没有调用写手' (@(Get-Content -LiteralPath $record).Count -eq $before)
    Assert-Case '5) 重放没有给账本添条目' ((Get-LedgerKeys $ledger).Count -eq 3)

    # ---- 6) 换 stamp 但内容未变：unchanged，不写 ----
    $digest4 = Join-Path $root 'digest-4.json'
    New-DigestFile -Path $digest4 -Stamp '20261115-110000' -Items @(
        (New-Row -Id 'a' -Stage '完成' -Achievement '本轮推进 A')
        (New-Row -Id 'b' -Stage '进行中' -Achievement '本轮推进 B')
    )
    $r = Invoke-Writeback @('-DigestPath', $digest4, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan, '-Apply', '-WriterScript', $writerPath)
    Assert-Case '6) 内容未变 -> unchanged=2 / apply=0 / 一行不写' (
        $r.ExitCode -eq 0 -and $r.Text -match 'unchanged=2' -and $r.Text -match 'apply=0' -and
        @(Get-Content -LiteralPath $record).Count -eq $before) "exit=$($r.ExitCode)"

    # ---- 7) 失败面 ----
    $digest5 = Join-Path $root 'digest-5.json'
    New-DigestFile -Path $digest5 -Stamp '20261115-120000' -Items @(
        (New-Row -Id 'a' -Stage '再改一次 A' -Achievement 'A2')
        (New-Row -Id 'b' -Stage '再改一次 B' -Achievement 'B2')
        (New-Row -Id 'c' -Stage '再改一次 C' -Achievement 'C2')
    )

    # 7a) 写手报失败：exit 1；成功行入账、失败行不入账，重试只补那一行
    $env:FAKE_WRITER_FAIL_IDS = 'b'
    $r = Invoke-Writeback @('-DigestPath', $digest5, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan, '-Apply', '-WriterScript', $writerPath)
    Assert-Case '7a) 有行写失败 -> 退出码 1 且点名列' ($r.ExitCode -eq 1 -and $r.Text -match 'FAIL\s+b' -and $r.Text -match 'fixture-injected-failure') "exit=$($r.ExitCode)"
    Assert-Case '7a) 成功行入账 2 条 / 失败行不入账' ((Get-LedgerKeys $ledger).Count -eq 5)
    Reset-WriterEnv
    $r = Invoke-Writeback @('-DigestPath', $digest5, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan, '-Apply', '-WriterScript', $writerPath)
    Assert-Case '7a) 原样重试只补失败那一行' ($r.ExitCode -eq 0 -and $r.Text -match 'apply=1' -and $r.Text -match 'replay=2') "exit=$($r.ExitCode)"
    Assert-Case '7a) 重试后账本齐 6 条' ((Get-LedgerKeys $ledger).Count -eq 6)

    # 7b) 写手输出不是 JSON：exit 1，整批不入账
    $digest6 = Join-Path $root 'digest-6.json'
    New-DigestFile -Path $digest6 -Stamp '20261115-130000' -Items @(
        (New-Row -Id 'a' -Stage '第三轮 A' -Achievement 'A3')
    )
    $env:FAKE_WRITER_GARBAGE = '1'
    $r = Invoke-Writeback @('-DigestPath', $digest6, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan, '-Apply', '-WriterScript', $writerPath)
    Assert-Case '7b) 写手输出非 JSON -> 退出码 1 且不入账' ($r.ExitCode -eq 1 -and (Get-LedgerKeys $ledger).Count -eq 6 -and $r.Text -match '不是 JSON') "exit=$($r.ExitCode)"
    Reset-WriterEnv

    # 7c) 写手漏报某行：该行按失败处理
    $env:FAKE_WRITER_DROP = 'a'
    $r = Invoke-Writeback @('-DigestPath', $digest6, '-StateFile', $state, '-LedgerFile', $ledger, '-Target', 'base/table', '-PlanFile', $plan, '-Apply', '-WriterScript', $writerPath)
    Assert-Case '7c) 写手漏报 -> 退出码 1 且该行不入账' ($r.ExitCode -eq 1 -and (Get-LedgerKeys $ledger).Count -eq 6 -and $r.Text -match '未回报') "exit=$($r.ExitCode)"
    Reset-WriterEnv

    # 7d) 账本损坏：fail-closed（不当空账重来）
    $badLedger = Join-Path $root 'state\bad-ledger.json'
    [System.IO.File]::WriteAllText($badLedger, '{ this is not json', $utf8)
    $r = Invoke-Writeback @('-DigestPath', $digest6, '-StateFile', $state, '-LedgerFile', $badLedger, '-Target', 'base/table', '-Apply', '-WriterScript', $writerPath)
    Assert-Case '7d) 账本损坏 -> 退出码 2 且不写' ($r.ExitCode -eq 2 -and $r.Text -match 'JSON') "exit=$($r.ExitCode)"
    $wrongVersion = Join-Path $root 'state\wrong-version.json'
    [System.IO.File]::WriteAllText($wrongVersion, '{"version":2,"entries":[]}', $utf8)
    $r = Invoke-Writeback @('-DigestPath', $digest6, '-StateFile', $state, '-LedgerFile', $wrongVersion, '-Target', 'base/table')
    Assert-Case '7d) 账本 version 不认识 -> 退出码 2' ($r.ExitCode -eq 2) "exit=$($r.ExitCode)"

    # 7e) 用法/环境错误
    $r = Invoke-Writeback @('-LedgerFile', $ledger)
    Assert-Case '7e) 缺 -DigestPath -> 退出码 2' ($r.ExitCode -eq 2) "exit=$($r.ExitCode)"
    $r = Invoke-Writeback @('-DigestPath', (Join-Path $root 'nope.json'), '-LedgerFile', $ledger)
    Assert-Case '7e) digest 不存在 -> 退出码 2' ($r.ExitCode -eq 2) "exit=$($r.ExitCode)"
    $noStamp = Join-Path $root 'digest-no-stamp.json'
    [System.IO.File]::WriteAllText($noStamp, '{"method":"bitable","items":[]}', $utf8)
    $r = Invoke-Writeback @('-DigestPath', $noStamp, '-LedgerFile', $ledger)
    Assert-Case '7e) digest 缺 stamp -> 退出码 2' ($r.ExitCode -eq 2) "exit=$($r.ExitCode)"
    $r = Invoke-Writeback @('-DigestPath', $digest1, '-StateFile', (Join-Path $root 'missing-state.json'), '-LedgerFile', $ledger)
    Assert-Case '7e) state 缺文件按「无运行态」继续（exit 0）' ($r.ExitCode -eq 0) "exit=$($r.ExitCode)"

    # ---- 8) 真 provider 缺能力声明时的失败面：不能假装写成功 ----
    $providerDigest = Join-Path $root 'digest-provider.json'
    New-DigestFile -Path $providerDigest -Stamp '20261115-140000' -Method 'csv-file' -Items @(
        (New-Row -Id 'a' -Stage '走 provider 槽' -Achievement 'P')
    )
    $r = Invoke-Writeback @('-DigestPath', $providerDigest, '-StateFile', $state, '-LedgerFile', (Join-Path $root 'state\provider-ledger.json'), '-Target', 'csv/x', '-Apply')
    Assert-Case '8) provider 没有 syncBack 能力 -> 退出码 1 且不入账' (
        $r.ExitCode -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $root 'state\provider-ledger.json'))) "exit=$($r.ExitCode)"
    Assert-Case '8) 失败原因点名能力槽' ($r.Text -match 'syncBack|能力槽')
}
finally {
    Reset-WriterEnv
    foreach ($k in @($savedEnv.Keys)) {
        [Environment]::SetEnvironmentVariable($k, $savedEnv[$k])
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("summary pass={0} fail={1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { Write-Host 'RESULT: FAIL'; exit 1 }
Write-Host 'RESULT: PASS'
exit 0
