#requires -Version 7
<#
.SYNOPSIS
  patrol-writeback.ps1 — 巡检结果回写层：preview-first 默认 + 幂等键 + 可重放账本。

.DESCRIPTION
  第 4 层 sync-back 的「先看计划、再敢落笔」版。patrol-loop.ps1 只把本轮结果写进
  digest（patrol-<stamp>.json）与运行态 state/，从不碰远端；本脚本把 digest 翻译成
  一张**可审阅的回写计划**（每行：写哪些字段、幂等键、为什么写/为什么不写），默认只打印，
  零网络零远端写入，连账本都不写。只有显式 `-Apply` 才真的落笔。

  为什么需要幂等键：巡检是周期任务，同一份 digest 会被重跑（进程被杀、触发器重试、
  人工复跑）。没有键就只能靠「记得刚才写过」，一重试就重复写、把远端字段覆盖成半旧值。
  本脚本给每行算一个确定性键：

      key = sha256("v1|<provider>|<target>|<stamp>|<itemId>|<payloadJson>")

  payload 是归一后的字段集（固定键序、压缩 JSON），所以：
    - 同一 digest 重放  -> 同键 -> 账本里已有 -> status=replay，不再写；
    - 换了 stamp 但内容一字没变 -> 键变、内容哈希没变 -> status=unchanged，也不写；
    - 内容变了 -> 新键 + 新内容哈希 -> status=apply。

  账本（默认 state/writeback-ledger.json）只追加、只记成功写入。账本损坏一律
  fail-closed（exit 2）：宁可停下，也不把未知账本当空账，否则下一次全量重写。

  写远端的路只有两条，本脚本不自己拼任何厂商命令：
    1. `-WriterScript <ps1>`：给自定义/离线用例用，脚本收到 `-PlanFile`（只含要写的行），
       必须往 stdout 打一个 JSON 对象 `{ "results": [ { "id": "...", "ok": true } ] }`；
    2. 不给 `-WriterScript` 时走 provider 的 `optional.syncBack` 能力槽
       （当前即 bitable 的 `Sync-BitableRoundResult`，它自己还有 `config.sync_back`
       这道门；门关着就返回 false，本脚本记 FAIL 而不是假装成功）。

  字段口径（与 Sync-BitableRoundResult 对齐，provider 自己负责映射到列名）：
  `currentStage` / `achievement` / `nextStep` / `threadId`，空值一律不写。取值顺序是
  「digest 行 -> state 记录」，两处都没有就不写——绝不凭空造值。注意 patrol-loop 产出的
  digest 与 state 目前都**不含** `nextStep`（它属于源表行，由源侧维护），所以默认情况下
  本脚本不会碰「下一步」列；要写它，digest 行里得真的带上该字段。

  只读边界：默认档对 digest / state / 账本只读，对远端零写入；`-Apply` 是唯一写入口。

.PARAMETER DigestPath
  patrol-loop.ps1 产出的 digest JSON（`scripts/downloads/patrol-<stamp>.json`）。

.PARAMETER StateFile
  运行态文件，默认 `<repo>/state/patrol-state.json`；用于补 threadId / nextStep。

.PARAMETER LedgerFile
  幂等账本，默认 `<repo>/state/writeback-ledger.json`。

.PARAMETER Provider
  provider 名，默认取 digest 的 `method`。参与幂等键，换源即换键空间。

.PARAMETER Target
  远端目标标识（如 `base_token/table_id`），参与幂等键；换表即换键空间，避免跨表误判重放。

.PARAMETER PlanFile
  把计划（含逐行状态、幂等键、字段）写成 JSON，便于人工审阅或交给下游。

.PARAMETER Apply
  真的写。缺省不写。

.PARAMETER WriterScript
  自定义写手脚本（离线用例 / 别的通道）。给了就不走 provider 能力槽。

.EXAMPLE
  # 只看计划（默认，零写入）
  pwsh -NoProfile -File scripts/patrol-writeback.ps1 -DigestPath scripts/downloads/patrol-20261112-082319.json -PlanFile $env:TEMP\plan.json

.EXAMPLE
  # 走 bitable 能力槽真写（前提：配置里 sync_back=true，且已人工批准这一轮）
  pwsh -NoProfile -File scripts/patrol-writeback.ps1 -DigestPath <digest> -Target "<base_token>/<table_id>" -Apply

.NOTES
  退出码：0 = preview 完成 / apply 全成功；1 = 有行写失败（失败行不入账，可原样重试）；
  2 = 用法或环境错误（digest 缺失/不是 JSON/缺 stamp、账本损坏）。
  只支持 PowerShell 7；本文件 UTF-8 无 BOM。
#>
[CmdletBinding()]
param(
    [string]$DigestPath = '',
    [string]$StateFile = '',
    [string]$LedgerFile = '',
    [string]$Provider = '',
    [string]$Target = '',
    [string]$PlanFile = '',
    [switch]$Apply,
    [string]$WriterScript = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:PayloadFields = @('currentStage', 'achievement', 'nextStep', 'threadId')

function Stop-Usage {
    param([string]$Message)
    [Console]::Error.WriteLine("[writeback] ERROR: $Message")
    exit 2
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Usage "$Label 不存在: $Path"
    }
    $raw = [System.IO.File]::ReadAllText($Path, $script:Utf8)
    if ([string]::IsNullOrWhiteSpace($raw)) { Stop-Usage "$Label 是空文件: $Path" }
    try { return ($raw | ConvertFrom-Json) }
    catch { Stop-Usage "$Label 不是合法 JSON: $Path -> $($_.Exception.Message)" }
}

function Test-Blank {
    param($Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrWhiteSpace($Value) }
    return $false
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:Utf8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-PropValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Read-WritebackLedger {
    # 账本刻意 fail-closed：损坏就是「不知道写过什么」，不能当空账重来一遍。
    param([Parameter(Mandatory)][string]$Path)
    $ledger = [ordered]@{ version = 1; entries = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $ledger }
    $raw = [System.IO.File]::ReadAllText($Path, $script:Utf8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $ledger }
    try { $parsed = $raw | ConvertFrom-Json }
    catch { Stop-Usage "账本不是合法 JSON（拒绝当空账处理）: $Path -> $($_.Exception.Message)" }
    $version = Get-PropValue $parsed 'version'
    $entries = Get-PropValue $parsed 'entries'
    if ($null -eq $version -or [int]$version -ne 1) {
        Stop-Usage "账本 version 不是 1（拒绝当空账处理）: $Path"
    }
    if ($null -eq $entries) { Stop-Usage "账本缺 entries 数组（拒绝当空账处理）: $Path" }
    $list = @()
    foreach ($e in @($entries)) {
        if ($null -eq $e) { continue }
        $key = [string](Get-PropValue $e 'key')
        if ([string]::IsNullOrWhiteSpace($key)) { Stop-Usage "账本里有条目缺 key（拒绝当空账处理）: $Path" }
        $list += $e
    }
    return [ordered]@{ version = 1; entries = $list }
}

function Save-WritebackLedger {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Ledger)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = [pscustomobject]@{
        version = 1
        entries = @($Ledger.entries)
    } | ConvertTo-Json -Depth 8
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function New-Payload {
    # 固定键序 + 压缩 JSON = 规范形式；同内容任何一次序列化都得到同一串。
    param($DigestItem, $StateRecord)
    $fields = [ordered]@{}
    foreach ($name in $script:PayloadFields) {
        $value = Get-PropValue $DigestItem $name
        if (Test-Blank $value) { $value = Get-PropValue $StateRecord $name }
        if (Test-Blank $value) { continue }
        $fields[$name] = [string]$value
    }
    $json = if ($fields.Count -eq 0) { '{}' } else { $fields | ConvertTo-Json -Depth 4 -Compress }
    return [pscustomobject]@{ Fields = $fields; Json = $json; Sha256 = (Get-Sha256Hex -Text $json) }
}

function New-WritebackPlan {
    param($Digest, [string]$ProviderName, [string]$TargetName, $State, $Ledger)
    $byKey = @{}
    foreach ($e in @($Ledger.entries)) { $byKey[[string](Get-PropValue $e 'key')] = $e }
    $lastApplied = @{}
    foreach ($e in @($Ledger.entries)) {
        $itemId = [string](Get-PropValue $e 'itemId')
        if ([string]::IsNullOrWhiteSpace($itemId)) { continue }
        $appliedAt = [string](Get-PropValue $e 'appliedAt')
        if (-not $lastApplied.ContainsKey($itemId) -or [string]::CompareOrdinal($appliedAt, [string](Get-PropValue $lastApplied[$itemId] 'appliedAt')) -gt 0) {
            $lastApplied[$itemId] = $e
        }
    }

    $stamp = [string](Get-PropValue $Digest 'stamp')
    $rows = @()
    $counts = [ordered]@{ apply = 0; replay = 0; unchanged = 0; empty = 0; noid = 0; total = 0 }
    foreach ($item in @(Get-PropValue $Digest 'items')) {
        if ($null -eq $item) { continue }
        $counts['total']++
        $id = [string](Get-PropValue $item 'id')
        if ([string]::IsNullOrWhiteSpace($id)) {
            $counts['noid']++
            $rows += [pscustomobject]@{ id = ''; status = 'noid'; idempotencyKey = ''; payloadSha256 = ''; fields = @() }
            continue
        }
        $stateRec = if ($State.ContainsKey($id)) { $State[$id] } else { $null }
        $payload = New-Payload -DigestItem $item -StateRecord $stateRec
        if ($payload.Fields.Count -eq 0) {
            $counts['empty']++
            $rows += [pscustomobject]@{ id = $id; status = 'empty'; idempotencyKey = ''; payloadSha256 = $payload.Sha256; fields = @() }
            continue
        }
        $keySource = 'v1|{0}|{1}|{2}|{3}|{4}' -f $ProviderName, $TargetName, $stamp, $id, $payload.Json
        $key = Get-Sha256Hex -Text $keySource
        $status = 'apply'
        if ($byKey.ContainsKey($key)) {
            $status = 'replay'
        }
        elseif ($lastApplied.ContainsKey($id) -and [string](Get-PropValue $lastApplied[$id] 'payloadSha256') -eq $payload.Sha256) {
            $status = 'unchanged'
        }
        $counts[$status]++
        $rows += [pscustomobject]@{
            id             = $id
            status         = $status
            idempotencyKey = $key
            payloadSha256  = $payload.Sha256
            fields         = @($payload.Fields.Keys)
            payload        = $payload.Fields
        }
    }
    return [pscustomobject]@{ stamp = $stamp; provider = $ProviderName; target = $TargetName; counts = $counts; items = $rows }
}

function Write-PlanFile {
    param([string]$Path, $Plan, [bool]$IsApply, $Results)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $items = @()
    foreach ($row in @($Plan.items)) {
        $entry = [ordered]@{
            id             = $row.id
            status         = $row.status
            idempotencyKey = $row.idempotencyKey
            payloadSha256  = $row.payloadSha256
            fields         = @($row.fields)
        }
        if ($row.PSObject.Properties['payload'] -and $row.payload) { $entry['payload'] = $row.payload }
        if ($Results -and $Results.ContainsKey($row.id)) { $entry['result'] = $Results[$row.id] }
        $items += $entry
    }
    $doc = [ordered]@{
        version = 1
        stamp   = $Plan.stamp
        provider= $Plan.provider
        target  = $Plan.target
        mode    = if ($IsApply) { 'apply' } else { 'preview' }
        counts  = $Plan.counts
        items   = $items
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 8), $script:Utf8)
}

function Invoke-PlanWriter {
    # 两条写通道，都在这里收口；返回 @{ <itemId> = @{ ok = [bool]; reason = '' } }
    param($Plan, [string]$Writer, [string]$ProviderName)
    $results = @{}
    $pending = @($Plan.items | Where-Object { $_.status -eq 'apply' })
    if ($pending.Count -eq 0) { return $results }

    $payload = [ordered]@{
        version = 1
        stamp   = $Plan.stamp
        provider= $ProviderName
        target  = $Plan.target
        items   = @($pending | ForEach-Object {
            [ordered]@{ id = $_.id; idempotencyKey = $_.idempotencyKey; payloadSha256 = $_.payloadSha256; payload = $_.payload }
        })
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-writeback-{0}.json' -f [guid]::NewGuid().ToString('n'))
    [System.IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Depth 8), $script:Utf8)
    try {
        if ($Writer) {
            if (-not (Test-Path -LiteralPath $Writer -PathType Leaf)) { Stop-Usage "WriterScript 不存在: $Writer" }
            $out = & pwsh -NoProfile -File $Writer -PlanFile $tmp 2>&1
            $code = $LASTEXITCODE
            $text = (@($out) | ForEach-Object { [string]$_ }) -join "`n"
            $parsed = $null
            try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null }
            if ($null -eq $parsed) {
                foreach ($row in $pending) {
                    $results[$row.id] = @{ ok = $false; reason = "writer 输出不是 JSON（exit=$code）: $($text.Trim())" }
                }
                return $results
            }
            $seen = @{}
            foreach ($r in @(Get-PropValue $parsed 'results')) {
                if ($null -eq $r) { continue }
                $rid = [string](Get-PropValue $r 'id')
                if ([string]::IsNullOrWhiteSpace($rid)) { continue }
                $ok = [bool](Get-PropValue $r 'ok')
                $reason = [string](Get-PropValue $r 'error')
                $results[$rid] = @{ ok = $ok; reason = $reason }
                $seen[$rid] = $true
            }
            foreach ($row in $pending) {
                if (-not $seen.ContainsKey($row.id)) {
                    $results[$row.id] = @{ ok = $false; reason = "writer 未回报该行（exit=$code）" }
                }
            }
            return $results
        }

        # provider 能力槽：复用既有装配层与它自己的门，不在这里拼厂商命令
        . (Join-Path $script:RepoRoot 'scripts\patrol-provider.ps1')
        $providerObj = Import-PatrolProvider -Provider $ProviderName
        foreach ($row in $pending) {
            $item = [pscustomobject]@{ id = $row.id }
            foreach ($k in $row.payload.Keys) { $item | Add-Member -NotePropertyName $k -NotePropertyValue $row.payload[$k] -Force }
            try {
                $ok = [bool](Sync-PatrolProviderRoundResult -Provider $providerObj -Item $item)
                $results[$row.id] = @{ ok = $ok; reason = if ($ok) { '' } else { 'provider 能力槽返回 false（syncBack 未声明，或配置门未开）' } }
            }
            catch {
                $results[$row.id] = @{ ok = $false; reason = $_.Exception.Message }
            }
        }
        return $results
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($DigestPath)) { Stop-Usage '必须给 -DigestPath（本轮 digest JSON）' }
if (-not $StateFile) { $StateFile = Join-Path $script:RepoRoot 'state\patrol-state.json' }
if (-not $LedgerFile) { $LedgerFile = Join-Path $script:RepoRoot 'state\writeback-ledger.json' }
if ($Apply -and $WriterScript -and -not (Test-Path -LiteralPath $WriterScript -PathType Leaf)) {
    Stop-Usage "WriterScript 不存在: $WriterScript"
}

$digest = Read-JsonFile -Path $DigestPath -Label 'digest'
$stamp = [string](Get-PropValue $digest 'stamp')
if ([string]::IsNullOrWhiteSpace($stamp)) { Stop-Usage "digest 缺 stamp: $DigestPath" }
$providerName = if ($Provider) { $Provider } else { [string](Get-PropValue $digest 'method') }
if ([string]::IsNullOrWhiteSpace($providerName)) { Stop-Usage "digest 缺 method 且未给 -Provider: $DigestPath" }

# state：只读、缺文件按「没有运行态」处理（与 patrol-state.ps1 的 Read-PatrolState 一致）
$stateById = @{}
if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
    . (Join-Path $script:RepoRoot 'scripts\patrol-state.ps1')
    $stateById = Read-PatrolState -Path $StateFile
}

$ledger = Read-WritebackLedger -Path $LedgerFile
$ledgerBefore = @($ledger.entries).Count
$plan = New-WritebackPlan -Digest $digest -ProviderName $providerName -TargetName $Target -State $stateById -Ledger $ledger

$mode = if ($Apply) { 'apply' } else { 'preview' }
Write-Host ("[plan] {0} stamp={1} provider={2} target={3} items={4} apply={5} replay={6} unchanged={7} empty={8} noid={9}" -f `
    $mode, $plan.stamp, $plan.provider, $(if ($Target) { $Target } else { '-' }), `
    $plan.counts['total'], $plan.counts['apply'], $plan.counts['replay'], $plan.counts['unchanged'], $plan.counts['empty'], $plan.counts['noid'])
foreach ($row in @($plan.items)) {
    $keyShort = if ($row.idempotencyKey) { $row.idempotencyKey.Substring(0, 12) } else { '-' }
    $fieldText = if (@($row.fields).Count -gt 0) { @($row.fields) -join ',' } else { '-' }
    Write-Host ("[plan] {0,-9} {1,-24} key={2} fields={3}" -f $row.status, $row.id, $keyShort, $fieldText)
}

if (-not $Apply) {
    Write-PlanFile -Path $PlanFile -Plan $plan -IsApply $false -Results $null
    if ($PlanFile) { Write-Host "[plan] written: $PlanFile" }
    Write-Host '[preview] 零远端写入、账本未改动；要落笔加 -Apply'
    exit 0
}

$results = Invoke-PlanWriter -Plan $plan -Writer $WriterScript -ProviderName $providerName
$failures = 0
$applied = 0
foreach ($row in @($plan.items)) {
    if ($row.status -ne 'apply') { continue }
    $res = $results[$row.id]
    if ($null -eq $res) { $res = @{ ok = $false; reason = '未收到写入结果' } }
    if ($res.ok) {
        $applied++
        $ledger.entries += [pscustomobject][ordered]@{
            key           = $row.idempotencyKey
            provider      = $plan.provider
            target        = $plan.target
            itemId        = $row.id
            stamp         = $plan.stamp
            payloadSha256 = $row.payloadSha256
            fields        = @($row.fields)
            appliedAt     = [DateTime]::UtcNow.ToString('o')
            writer        = if ($WriterScript) { $WriterScript } else { "provider:$providerName" }
        }
        Write-Host ("[apply] ok       {0,-24} key={1}" -f $row.id, $row.idempotencyKey.Substring(0, 12))
    }
    else {
        $failures++
        Write-Host ("[apply] FAIL     {0,-24} key={1} reason={2}" -f $row.id, $row.idempotencyKey.Substring(0, 12), $res.reason)
    }
}

if ($applied -gt 0) {
    Save-WritebackLedger -Path $LedgerFile -Ledger $ledger
}
Write-PlanFile -Path $PlanFile -Plan $plan -IsApply $true -Results $results
Write-Host ("[ledger] {0} entries {1} -> {2}" -f $LedgerFile, $ledgerBefore, @($ledger.entries).Count)
if ($PlanFile) { Write-Host "[plan] written: $PlanFile" }
Write-Host ("[done] {0} applied={1} failed={2} skipped={3}" -f $mode, $applied, $failures, ($plan.counts['total'] - $plan.counts['apply']))
if ($failures -gt 0) { exit 1 }
exit 0
