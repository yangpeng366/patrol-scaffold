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

function Get-BitableRowValue {
    # 按列名取单元格。行可能是 Convert-LarkMatrix 出来的 PSCustomObject，也可能是 hashtable
    #（测试 fixture / ConvertFrom-Json -AsHashtable），两种都要能取。缺列返回 $null——
    # 「缺列」与「空值」在下游是同一种「没有」，但归一规则必须由本函数调用的地方统一决定。
    param($Row, [string]$Name)
    if ($null -eq $Row -or [string]::IsNullOrEmpty($Name)) { return $null }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains($Name)) { return $Row[$Name] }
        return $null
    }
    $prop = $Row.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Convert-BitableRowToItem {
    # Normalize a single Bitable row PSCustomObject (already converted via
    # Convert-LarkMatrix) into the patrol item shape.
    #
    # 归一规则与 dsh-patrol `src/source/provider.ts::normalizeItem`（经 bitable.ts COLUMNS 映射）
    # 逐条同一口径——两仓对同一行必须解析出同一个 item。对拍闸门：
    # tests/verify-item-parity-e2e.ps1（同一份 fixture 行同时喂两侧，逐字段比，不等即 exit 1）。
    # 本函数里任何一条规则改动，都要先跑那个脚本，否则两仓会静默漂移。
    #
    # 语义要点（都以「调度层负责兜底」为前提，解析层只如实翻译行数据）：
    #   priority    P0/P1 保留，其余（P3/空/大小写杂乱）一律 P2（schema enum 只有三个值）
    #   intervalMin 0 / 缺列 / 非法 一律 0；0 表示「最短间隔为 0」，由调度器决定怎么回退
    #               —— 这里绝不能把 0 改写成 60，否则「0 = 每轮到期」的行会被悄悄改成 60 分钟一轮
    #   threadId    空串与缺列都是 null（不是 ''），下游判断「有没有会话可续跑」只看 truthy
    #   fake        只认 Bitable 复选框的真布尔 true；字符串 "true"/"1"/"是" 一律 false
    #   title/id/nextStep 去首尾空白；description/repoPath 等原样保留
    #   授权边界/协作形态/审批状态 有缺省值（自主 / sparse / 已通过），与 dsh 同默认
    #
    # 注：title 不再回退 record_id——契约层 scripts/patrol-provider.ps1::ConvertTo-PatrolItem
    # 在收口处用 id 补齐空标题（schema 要求 title minLength 1），解析层保持与 dsh 同形。
    param(
        [Parameter(Mandatory)]$Row,
        [string]$RepoPathField = '仓库路径',
        [string]$TitleField = '项目名',
        [string]$DescriptionField = '简要描述',
        [string]$NextStepField = '下一步',
        [string]$PriorityField = '优先级',
        [string]$IntervalField = '巡检间隔(分钟)',
        [string]$FakeField = '假数据模式',
        [string]$ThreadIdField = 'codex_thread_id',
        [string]$CurrentStageField = '当前阶段',
        [string]$AchievementField = '外部成就',
        [string]$AuthorizationField = '授权边界',
        [string]$CollaborationField = '协作形态',
        [string]$ApprovalField = '审批状态',
        [string]$PendingActionField = '待审行动',
        [string]$CategoryField = '分类',
        [string]$LastRunField = '最近执行时间'
    )

    $str = {
        param($value)
        if ($null -eq $value) { return '' }
        return [string]$value
    }

    # priority：去首尾空白 + 大写，只保留 P0/P1
    $priorityRaw = ([string](& $str (Get-BitableRowValue -Row $Row -Name $PriorityField))).Trim().ToUpperInvariant()
    $priority = if ($priorityRaw -eq 'P0' -or $priorityRaw -eq 'P1') { $priorityRaw } else { 'P2' }

    # intervalMin：缺列 / 非数字 / <=0 一律 0；小数向下取整（45.7 -> 45，与 JS Math.floor 同口径）。
    # 不用 [int] 强转：那是四舍五入（45.7 -> 46），会和 dsh 的 floor 差 1 分钟。
    $intervalMin = 0
    $intervalRaw = Get-BitableRowValue -Row $Row -Name $IntervalField
    if ($null -ne $intervalRaw) {
        try {
            $numeric = [double]$intervalRaw
            if (-not [double]::IsNaN($numeric) -and -not [double]::IsInfinity($numeric) -and $numeric -gt 0) {
                $intervalMin = [int][math]::Floor($numeric)
            }
        }
        catch { $intervalMin = 0 }
    }

    # fake：只认真正的布尔 true（Bitable 复选框）；'true'/'1'/'yes'/'on' 这类字符串不算开。
    $fakeRaw = Get-BitableRowValue -Row $Row -Name $FakeField
    $fake = [bool](($fakeRaw -is [bool]) -and $fakeRaw)

    # threadId / lastRun：空串与缺列都是 null（与 dsh 同形）
    $threadIdRaw = & $str (Get-BitableRowValue -Row $Row -Name $ThreadIdField)
    $threadId = if ($threadIdRaw -eq '') { $null } else { $threadIdRaw }
    $lastRunRaw = & $str (Get-BitableRowValue -Row $Row -Name $LastRunField)
    $lastRun = if ($lastRunRaw -eq '') { $null } else { $lastRunRaw }

    # 三列有缺省值的字段：空值走默认（与 dsh `str(v) || '默认'` 同语义）
    $authorization = & $str (Get-BitableRowValue -Row $Row -Name $AuthorizationField)
    if (-not $authorization) { $authorization = '自主' }
    $collaboration = & $str (Get-BitableRowValue -Row $Row -Name $CollaborationField)
    if (-not $collaboration) { $collaboration = 'sparse' }
    $approval = & $str (Get-BitableRowValue -Row $Row -Name $ApprovalField)
    if (-not $approval) { $approval = '已通过' }

    return [pscustomobject]@{
        id          = (& $str (Get-BitableRowValue -Row $Row -Name 'record_id')).Trim()
        title       = (& $str (Get-BitableRowValue -Row $Row -Name $TitleField)).Trim()
        repoPath    = & $str (Get-BitableRowValue -Row $Row -Name $RepoPathField)
        description = & $str (Get-BitableRowValue -Row $Row -Name $DescriptionField)
        nextStep    = (& $str (Get-BitableRowValue -Row $Row -Name $NextStepField)).Trim()
        priority    = $priority
        intervalMin = $intervalMin
        threadId    = $threadId
        fake        = $fake
        lastRun     = $lastRun
        currentStage = & $str (Get-BitableRowValue -Row $Row -Name $CurrentStageField)
        achievement  = & $str (Get-BitableRowValue -Row $Row -Name $AchievementField)
        authorization = $authorization
        collaboration = $collaboration
        approval      = $approval
        pendingAction = & $str (Get-BitableRowValue -Row $Row -Name $PendingActionField)
        category      = & $str (Get-BitableRowValue -Row $Row -Name $CategoryField)
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
