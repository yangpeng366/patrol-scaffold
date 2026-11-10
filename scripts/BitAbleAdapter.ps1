# scripts\BitAbleAdapter.ps1
# Bitable adapter for patrol-scaffold (provider=bitable).
# Same provider contract as local-json-adapter:
#   Get-PatrolItems       list-items()
#   Save-PatrolItems      write-back()
#   Resolve-ItemName      resolve-name()
#
# Note: This adapter is opt-in and dry-run-first. It reads Bitable rows via
# lark-cli base, normalizes them into the common item shape, and writes the
# worker result back via lark-cli base +record-upsert when -SyncBack is set.
#
# All Bitable writes are gated by both config (`sync_back=true`) AND CLI flag
# (`-SyncBack`). Default behavior is read-only + dry-run-friendly.

$script:NoBom = [System.Text.UTF8Encoding]::new($false)

function Resolve-PatrolBitableHelperPath {
    # 外部依赖 lark-base-helpers.ps1 不随本仓分发（开源仓不该绑死本机路径）。
    # 查找顺序：环境变量 PATROL_BITABLE_HELPERS_PATH -> 约定的兄弟仓相对路径。
    $candidates = @()
    if ($env:PATROL_BITABLE_HELPERS_PATH) { $candidates += $env:PATROL_BITABLE_HELPERS_PATH }
    $candidates += (Join-Path $PSScriptRoot '..\..\auto-deploy\_inter-agent\lark-base-helpers.ps1')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw "lark-base-helpers.ps1 not found; set PATROL_BITABLE_HELPERS_PATH or place it at $($candidates[-1])"
}

function Convert-BitableRowToItem {
    # Normalize a single Bitable row PSCustomObject (already converted via
    # Convert-LarkMatrix) into the patrol item shape.
    param(
        [Parameter(Mandatory)]$Row,
        [string]$RepoPathField = '仓库路径',
        [string]$TitleField = '项目名',
        [string]$DescriptionField = '简要描述',
        [string]$NextStepField = '下一步',
        [string]$PriorityField = '优先级',
        [string]$IntervalField = '巡检间隔(分钟)',
        [string]$FakeField = '假数据模式',
        [string]$ThreadIdField = 'codex_thread_id'
    )
    $title = if ($Row.$TitleField) { [string]$Row.$TitleField } else { [string]$Row.record_id }
    $priority = if ($Row.$PriorityField) { ([string]$Row.$PriorityField -replace '\s', '').Trim() } else { 'P2' }
    $interval = 60
    try { if ($null -ne $Row.$IntervalField) { $interval = [int]$Row.$IntervalField } } catch { $interval = 60 }
    if ($interval -le 0) { $interval = 60 }
    $fake = $false
    if ($Row.$FakeField -is [bool]) { $fake = [bool]$Row.$FakeField }
    elseif ($null -ne $Row.$FakeField) {
        $fake = ([string]$Row.$FakeField).Trim().ToLowerInvariant() -in @('true', '1', 'yes', 'on')
    }
    $threadId = if ($null -ne $Row.$ThreadIdField) { [string]$Row.$ThreadIdField } else { '' }
    $repoPath = if ($Row.$RepoPathField) { [string]$Row.$RepoPathField } else { '' }
    return [pscustomobject]@{
        id = [string]$Row.record_id
        title = $title
        repoPath = $repoPath
        description = if ($Row.$DescriptionField) { [string]$Row.$DescriptionField } else { '' }
        nextStep = if ($Row.$NextStepField) { [string]$Row.$NextStepField } else { '' }
        priority = $priority
        intervalMin = $interval
        threadId = $threadId
        fake = $fake
        lastRun = $null
        currentStage = ''
        achievement = ''
    }
}

function Get-PatrolItems {
    # list-items(): read Bitable rows + normalize. 契约名与 local-json 适配器一致。
    param(
        [Parameter(Mandatory)][string]$BitableConfigPath,
        [string]$Identity = 'user'
    )
    $helperPath = Resolve-PatrolBitableHelperPath
    . $helperPath
    Initialize-LarkEnvironment
    $cfg = Get-LarkConfig -ConfigPath $BitableConfigPath
    $raw = Invoke-LarkBaseRaw -LarkCli $cfg.lark_cli -LarkArgs @(
        'base', '+record-list',
        '--base-token', $cfg.base_token,
        '--table-id', $cfg.table_ids.tasks,
        '--limit', '100',
        '--as', $Identity
    ) -NotifyUserOid $cfg.notify.user_open_id -ReauthFile (Join-Path $PSScriptRoot '..\..\auto-deploy\REAUTH_REQUIRED.txt')
    if (-not $raw.ok) {
        throw "Bitable read failed: $($raw.raw)"
    }
    $rows = Convert-LarkMatrix -Data $raw
    $items = @()
    foreach ($row in $rows) {
        $items += Convert-BitableRowToItem -Row $row
    }
    return $items
}

function Save-PatrolItems {
    # write-back(): persist items into a local tasks.json (so patrol-scaffold's
    # provider is the durable local-json form). If SyncBack is requested via
    # the bootstrapper, it issues Bitable upserts outside this function.
    param([Parameter(Mandatory)][string]$TasksFile, [Parameter(Mandatory)]$Items)
    $arr = @($Items)
    $json = $arr | ConvertTo-Json -Depth 6 -AsArray
    [System.IO.File]::WriteAllText($TasksFile, $json, $script:NoBom)
}

function Resolve-ItemName {
    param($Item)
    return $Item.title
}

function Sync-BitableRoundResult {
    # Optional write-back to Bitable for one item. Requires SyncBackEnabled
    # in config and is otherwise a no-op.
    param(
        [Parameter(Mandatory)][string]$BitableConfigPath,
        [Parameter(Mandatory)]$Item,
        [string]$Identity = 'user'
    )
    $helperPath = Resolve-PatrolBitableHelperPath
    . $helperPath
    Initialize-LarkEnvironment
    $cfg = Get-LarkConfig -ConfigPath $BitableConfigPath
    if (-not $cfg.sync_back) { return $false }
    $fields = [ordered]@{}
    if ($Item.currentStage) { $fields['当前阶段'] = [string]$Item.currentStage }
    if ($Item.achievement) { $fields['外部成就'] = [string]$Item.achievement }
    if ($Item.nextStep) { $fields['下一步'] = [string]$Item.nextStep }
    if ($Item.threadId) { $fields['codex_thread_id'] = [string]$Item.threadId }
    if ($fields.Count -eq 0) { return $false }
    $json = $fields | ConvertTo-Json -Depth 4
    $raw = Invoke-LarkBaseRaw -LarkCli $cfg.lark_cli -LarkArgs @(
        'base', '+record-upsert',
        '--base-token', $cfg.base_token,
        '--table-id', $cfg.table_ids.tasks,
        '--record-id', [string]$Item.id,
        '--json', $json,
        '--as', $Identity
    ) -NotifyUserOid $cfg.notify.user_open_id -ReauthFile (Join-Path $PSScriptRoot '..\..\auto-deploy\REAUTH_REQUIRED.txt')
    return [bool]$raw.ok
}

function Read-PatrolItems {
    # 兼容旧名（v1 描述符曾声明 Read-PatrolItems）；契约名以 Get-PatrolItems 为准。
    param([Parameter(Mandatory)][string]$BitableConfigPath, [string]$Identity = 'user')
    return @(Get-PatrolItems -BitableConfigPath $BitableConfigPath -Identity $Identity)
}
