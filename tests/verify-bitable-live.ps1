#requires -Version 7
<#
.SYNOPSIS
  verify-bitable-live.ps1 — Bitable 只读实跑闸门（默认离线自测 + SKIP，exit 0）。

.DESCRIPTION
  三档语义（对应「绿了却什么都没测」的四个洞）：
    · 默认（不带 -Live / -RequireLive）：跑完全部离线自测（零凭据零网络），live 段打印 SKIP，exit 0。
      CI 走这一档，但 CI 不再是「什么都没测」——四类失败面都有离线自证覆盖。
    · -Live：真读方向表。真读过程中的任何失败（lark-cli 非零退出、JSON 解析失败、字段缺失、
      行数不符、语义断言不过）一律 FAIL；只有「环境没准备好」（找不到 lark-cli、user 身份未就绪）
      才算 SKIP。鉴权失败（lark-cli 退出码非 0）无论哪档都算 FAIL，不算 SKIP。
    · -RequireLive：要求真读且必须成功。此时任何 SKIP（含缺工具、缺凭据）都判 FAIL。

  闸门真在测什么：
    1. 内容语义：必须存在 intervalMin > 0 的在跑行；在跑行标题必须非空；空标题行数照实报出。
       （旧口径只数行数：归一时 intervalMin 空/非数字一律落 0，于是「78 行全停跑」与
        「78 行里 12 行在跑」在闸门眼里一模一样，照样 PASS。）
    2. 行数口径：-ExpectedRows（默认 78）精确比对；「只要求非空」必须显式 -AnyRowCount，
       且强制行数下限 -MinRows（默认 1）。环境变量 PATROL_BITABLE_EXPECTED_ROWS 覆盖到 0 一律
       报错，不再静默退化成「读到 1 行即过」。
    3. 列按表头名取：字段名缺失即 FAIL 并点名；页数只断言「不超过上限 / 没有空页 / 逐页行数自洽」，
       不再写死「每页必满」（服务端少返几行不该假红）。

  只读边界：本脚本只调用 `lark-cli base +record-list` 与 `lark-cli auth status`，
  绝不调用 +record-upsert / +record-batch-create / +record-batch-update / +record-delete。

.EXAMPLE
  pwsh -NoProfile -File tests/verify-bitable-live.ps1
  # -> 离线自测全过 + [SKIP] live bitable read，exit 0

.EXAMPLE
  pwsh -NoProfile -File tests/verify-bitable-live.ps1 -Live
  # -> 真读方向表 78 行（12 在跑 / 66 停跑），语义断言过，exit 0

.EXAMPLE
  pwsh -NoProfile -File tests/verify-bitable-live.ps1 -RequireLive
  # -> 要求实跑：缺工具/缺凭据也判红；本机真读成功则 exit 0

.EXAMPLE
  pwsh -NoProfile -File tests/verify-bitable-live.ps1 -Live -AnyRowCount -MinRows 10
  # -> 表行数变化时仍可跑：只要求「至少 10 行 + 至少一条在跑行」
#>
[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$RequireLive,
    [switch]$AnyRowCount,
    [string]$BaseToken = '',
    [string]$TableId = '',
    [string]$LarkCli = '',
    [int]$ExpectedRows = 78,
    [int]$MinRows = 1,
    [int]$PageSize = 50,
    [int]$MaxPages = 200
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# 资源 ID 默认指向方向表；它们不是 bearer 凭据，真正鉴权由 lark-cli user OAuth 完成。
# 仍允许环境变量 / 参数覆盖，方便换表或换机器。
if (-not $BaseToken) {
    $BaseToken = if ($env:PATROL_BITABLE_BASE_TOKEN) { $env:PATROL_BITABLE_BASE_TOKEN } else { 'Vb6pb5SJ4aWpEpsqPxvcR5Tqnte' }
}
if (-not $TableId) {
    $TableId = if ($env:PATROL_BITABLE_TABLE_ID) { $env:PATROL_BITABLE_TABLE_ID } else { 'tbl2XGd8bO10NBY5' }
}
if (-not $LarkCli) {
    $LarkCli = if ($env:PATROL_BITABLE_LARK_CLI) { $env:PATROL_BITABLE_LARK_CLI } else { 'lark-cli' }
}

# 行数口径的环境覆盖值原样留存，交给 Resolve-ExpectedRowsPolicy 判定：
# 覆盖到 0 必须在策略层报错，不许在这里静默降级。
$expectedRowsEnvRaw = [string]$env:PATROL_BITABLE_EXPECTED_ROWS

. (Join-Path $repoRoot 'scripts\BitAbleAdapter.ps1')
. (Join-Path $repoRoot 'scripts\patrol-provider.ps1')

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Write-Pass {
    param([string]$Label, [string]$Detail = '')
    Write-Host ("[PASS] {0}{1}" -f $Label, $(if ($Detail) { "  $Detail" } else { '' }))
    $script:Pass++
}

function Write-Fail {
    param([string]$Label, [string]$Detail = '')
    Write-Host ("[FAIL] {0}{1}" -f $Label, $(if ($Detail) { "  $Detail" } else { '' }))
    $script:Fail++
}

function Write-Skip {
    param([string]$Label, [string]$Detail = '')
    Write-Host ("[SKIP] {0}{1}" -f $Label, $(if ($Detail) { "  $Detail" } else { '' }))
    $script:Skip++
}

function Assert-True {
    param([bool]$Condition, [string]$Label, [string]$Detail = '')
    if ($Condition) { Write-Pass -Label $Label -Detail $Detail }
    else { Write-Fail -Label $Label -Detail $Detail }
    # 调用方只关心副作用，刻意不返回值（否则管道会多打印 True/False）。
}

function Get-FirstOutputLine {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $line = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($line.Count -eq 0) { return '' }
    $value = [string]$line[0]
    if ($value.Length -gt 300) { return $value.Substring(0, 300) + '...' }
    return $value
}

function Invoke-LarkCliCapture {
    # 只负责启动与收口退出码；命令内容由调用方决定（本脚本只会传只读参数）。
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $global:LASTEXITCODE = 0
    try {
        $text = (& $FilePath @ArgumentList 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        return [pscustomobject]@{ ExitCode = [int]$code; Output = $text }
    }
    catch {
        return [pscustomobject]@{ ExitCode = 127; Output = $_.Exception.Message }
    }
}

function ConvertFrom-LarkJson {
    param([string]$Text)
    try {
        return ($Text | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String)
    }
    catch {
        $start = $Text.IndexOf('{')
        $end = $Text.LastIndexOf('}')
        if ($start -ge 0 -and $end -gt $start) {
            try {
                return ($Text.Substring($start, $end - $start + 1) | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String)
            }
            catch { }
        }
        throw ("lark-cli 输出不是 JSON（首行：{0}）" -f (Get-FirstOutputLine -Text $Text))
    }
}

function Get-CliArgValue {
    param([string[]]$CliArgs, [string]$Name, [string]$Default = '')
    for ($i = 0; $i -lt $CliArgs.Count - 1; $i++) {
        if ($CliArgs[$i] -eq $Name) { return [string]$CliArgs[$i + 1] }
    }
    return $Default
}

function Read-BitableRowsPaged {
    # 只读分页读取。lark-cli 的 json 输出在 has_more=true 时可能不返回 next_offset，
    # 此时以 offset + 本页行数前进；若仍不前进就明确报错，绝不空转。
    # 逐页行数一并返回，供「逐页行数自洽」断言用（不写死「每页必满」）。
    param(
        [Parameter(Mandatory)][string]$BaseToken,
        [Parameter(Mandatory)][string]$TableId,
        [Parameter(Mandatory)][string]$LarkCli,
        [int]$PageSize = 50,
        [int]$MaxPages = 200,
        [scriptblock]$Invoke = $null
    )
    if ($PageSize -lt 1 -or $PageSize -gt 200) { throw "PageSize 必须在 1..200（lark-cli json limit 限制），实际 $PageSize" }
    if ($MaxPages -lt 1) { throw "MaxPages 必须 >= 1，实际 $MaxPages" }
    if ($null -eq $Invoke) {
        $Invoke = { param($cli, $cliArgs) Invoke-LarkCliCapture -FilePath $cli -ArgumentList $cliArgs }
    }

    $offset = 0
    $pages = 0
    $fields = $null
    $rows = [System.Collections.Generic.List[object]]::new()
    $seenIds = [System.Collections.Generic.HashSet[string]]::new()
    $pageOffsets = [System.Collections.Generic.List[int]]::new()
    $pageRowCounts = [System.Collections.Generic.List[int]]::new()

    while ($true) {
        if ($pages -ge $MaxPages) {
            throw ("分页超过 MaxPages={0}（offset={1}）；拒绝无限翻页" -f $MaxPages, $offset)
        }
        $cliArgs = @(
            'base', '+record-list',
            '--base-token', $BaseToken,
            '--table-id', $TableId,
            '--limit', [string]$PageSize,
            '--offset', [string]$offset,
            '--format', 'json',
            '--as', 'user'
        )
        $res = & $Invoke $LarkCli $cliArgs
        if ($null -eq $res) { throw ("lark-cli 未返回结果（offset={0}）" -f $offset) }
        $exitCode = if ($null -ne $res.ExitCode) { [int]$res.ExitCode } else { 0 }
        if ($exitCode -ne 0) {
            throw ("lark-cli base +record-list 失败（exit={0}，offset={1}）：{2}" -f $exitCode, $offset, (Get-FirstOutputLine -Text ([string]$res.Output)))
        }

        $json = ConvertFrom-LarkJson -Text ([string]$res.Output)
        if ($json['ok'] -ne $true) {
            throw ("lark-cli base +record-list 返回 ok!=true（offset={0}）：{1}" -f $offset, (Get-FirstOutputLine -Text ([string]$res.Output)))
        }
        $data = $json['data']
        if ($null -eq $data) { throw ("lark-cli base +record-list 缺 data（offset={0}）" -f $offset) }

        $pageFields = @($data['fields'])
        $matrix = @($data['data'])
        $pageIds = @($data['record_id_list'])
        if ($pageFields.Count -eq 0) { throw ("字段列表为空（offset={0}）" -f $offset) }
        if ($matrix.Count -ne $pageIds.Count) {
            throw ("行数与 record_id_list 不一致（offset={0}）：rows={1} ids={2}" -f $offset, $matrix.Count, $pageIds.Count)
        }

        if ($null -eq $fields) {
            $fields = $pageFields
        }
        else {
            $oldKey = [string]::Join([char]0, $fields)
            $newKey = [string]::Join([char]0, $pageFields)
            if ($oldKey -ne $newKey) {
                throw ("翻页过程中字段列表发生变化（offset={0}）；拒绝把不同 schema 的行混在一起" -f $offset)
            }
        }

        for ($i = 0; $i -lt $matrix.Count; $i++) {
            $recordId = [string]$pageIds[$i]
            if (-not $recordId) { throw ("record_id_list[{0}] 为空（offset={1}）" -f $i, $offset) }
            if (-not $seenIds.Add($recordId)) {
                throw ("分页重叠：record_id '{0}' 在 offset={1} 重复出现" -f $recordId, $offset)
            }
            if (@($matrix[$i]).Count -ne $pageFields.Count) {
                throw ("第 {0} 行单元格数={1}，与字段数={2} 不一致" -f ($offset + $i), (@($matrix[$i]).Count), $pageFields.Count)
            }
            $rows.Add([pscustomobject]@{ record_id = $recordId; values = @($matrix[$i]) })
        }

        $pageOffsets.Add($offset)
        $pageRowCounts.Add($matrix.Count)
        $pages++

        $hasMore = ($data['has_more'] -eq $true)
        if (-not $hasMore -and [string]$data['has_more'] -eq 'true') { $hasMore = $true }
        if (-not $hasMore) { break }

        $nextRaw = $data['next_offset']
        $next = 0
        $hasNext = $false
        if ($null -ne $nextRaw -and [string]$nextRaw -ne '') {
            $parsedNext = 0
            if ([int]::TryParse([string]$nextRaw, [ref]$parsedNext)) {
                $next = $parsedNext
                $hasNext = $true
            }
        }
        if (-not $hasNext) { $next = $offset + $matrix.Count }
        if ($next -le $offset) {
            throw ("pagination did not advance / 分页未前进（offset={0}, next_offset={1}, rows={2}）；拒绝空转" -f $offset, $next, $matrix.Count)
        }
        $offset = $next
    }

    return [pscustomobject]@{
        Fields       = @($fields)
        Rows         = @($rows)
        PageOffsets  = @($pageOffsets)
        PageRowCounts = @($pageRowCounts)
        Pages        = $pages
    }
}

function ConvertTo-CellScalar {
    # 数组单元格 join ', '（与 lark-base-helpers.ps1::Convert-LarkMatrix 同口径）。
    param($Value)
    if ($Value -is [array]) { return ($Value -join ', ') }
    return $Value
}

function ConvertFrom-BitableRowSet {
    # 矩阵 -> 按表头名的行对象。位置只用于解码服务端返回的矩阵，键一律用表头名。
    param(
        [Parameter(Mandatory)][string[]]$FieldNames,
        [Parameter(Mandatory)]$Rows
    )
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) {
        $obj = [ordered]@{ record_id = [string]$row.record_id }
        $values = @($row.values)
        for ($j = 0; $j -lt $FieldNames.Count; $j++) {
            $obj[[string]$FieldNames[$j]] = ConvertTo-CellScalar -Value $values[$j]
        }
        $out.Add([pscustomobject]$obj)
    }
    return @($out)
}

function Get-FieldValueByName {
    # 按表头名取单元格：位置无关，列序换了也不会错列。
    # 表头名不存在 -> 返回 $null（调用方据此判「列缺失」，不许静默取到别的列）。
    param(
        [Parameter(Mandatory)][string[]]$FieldNames,
        $Values,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Values) { return $null }
    $cells = @($Values)
    for ($i = 0; $i -lt $FieldNames.Count; $i++) {
        if ([string]$FieldNames[$i] -eq $Name) {
            if ($i -ge $cells.Count) { return $null }
            return ConvertTo-CellScalar -Value $cells[$i]
        }
    }
    return $null
}

function Get-BitableRowSemantics {
    # 按表头名统计内容语义：在跑行数、停跑行数、空标题行数。
    # 口径与 scripts/BitAbleAdapter.ps1::Convert-BitableRowToItem 一致：
    #   intervalMin —— 缺列/空/非数字/<0 一律 0（停跑）；>0 则向下取整。
    #   title       —— 原样去空白判空（不拿 record_id 兜底，兜底是契约层的事）。
    param(
        [Parameter(Mandatory)][string[]]$FieldNames,
        [Parameter(Mandatory)]$Rows,
        [string]$TitleField = '项目名',
        [string]$IntervalField = '巡检间隔(分钟)'
    )
    $titleIdx = -1
    $intervalIdx = -1
    for ($i = 0; $i -lt $FieldNames.Count; $i++) {
        if ([string]$FieldNames[$i] -eq $TitleField) { $titleIdx = $i }
        if ([string]$FieldNames[$i] -eq $IntervalField) { $intervalIdx = $i }
    }
    $missing = @()
    if ($titleIdx -lt 0) { $missing += $TitleField }
    if ($intervalIdx -lt 0) { $missing += $IntervalField }

    $total = 0; $active = 0; $disabled = 0
    $emptyTitles = 0; $nonEmptyTitles = 0; $activeWithoutTitle = 0
    $emptyTitleIds = @(); $activeWithoutTitleIds = @(); $activeTitles = @()
    foreach ($row in @($Rows)) {
        $total++
        $values = @($row.values)
        $title = ''
        if ($titleIdx -ge 0 -and $titleIdx -lt $values.Count) {
            $title = ([string](ConvertTo-CellScalar -Value $values[$titleIdx])).Trim()
        }
        $isActive = $false
        if ($intervalIdx -ge 0 -and $intervalIdx -lt $values.Count) {
            $raw = $values[$intervalIdx]
            if ($null -ne $raw -and -not ($raw -is [array])) {
                try {
                    $numeric = [double]$raw
                    if (-not [double]::IsNaN($numeric) -and -not [double]::IsInfinity($numeric) -and $numeric -gt 0) { $isActive = $true }
                }
                catch { $isActive = $false }
            }
        }
        if ($isActive) {
            $active++
            $activeTitles += $title
            if (-not $title) { $activeWithoutTitle++; $activeWithoutTitleIds += [string]$row.record_id }
        }
        else { $disabled++ }
        if ($title) { $nonEmptyTitles++ } else { $emptyTitles++; $emptyTitleIds += [string]$row.record_id }
    }

    return [pscustomobject]@{
        Total                 = $total
        ActiveCount           = $active
        DisabledCount         = $disabled
        EmptyTitleCount       = $emptyTitles
        NonEmptyTitleCount    = $nonEmptyTitles
        ActiveWithoutTitleCount = $activeWithoutTitle
        MissingFields         = @($missing)
        EmptyTitleIds         = @($emptyTitleIds)
        ActiveWithoutTitleIds = @($activeWithoutTitleIds)
        ActiveTitles          = @($activeTitles)
    }
}

function Invoke-SemanticChecks {
    # 内容语义闸门。$Assert 可注入：实跑用 Assert-True（写全局计数），
    # 离线自证用本地收集器（不污染全局计数，才能自证「全 0 行会判红」）。
    param(
        [Parameter(Mandatory)]$Analysis,
        [Parameter(Mandatory)][scriptblock]$Assert
    )
    & $Assert ($Analysis.MissingFields.Count -eq 0) `
        'live: required columns present by header name' `
        ("missing={0}" -f ($Analysis.MissingFields -join ','))
    & $Assert ($Analysis.ActiveCount -gt 0) `
        'live: at least one active row (intervalMin > 0)' `
        ("active={0} disabled={1} total={2}" -f $Analysis.ActiveCount, $Analysis.DisabledCount, $Analysis.Total)
    & $Assert ($Analysis.ActiveWithoutTitleCount -eq 0) `
        'live: every active row has a non-empty title' `
        ("bad={0} activeTitles={1}" -f ($Analysis.ActiveWithoutTitleIds -join ','), ($Analysis.ActiveTitles -join ' / '))
    & $Assert ($Analysis.NonEmptyTitleCount -gt 0) `
        'live: at least one row has a non-empty title' `
        ("nonEmpty={0} empty={1}" -f $Analysis.NonEmptyTitleCount, $Analysis.EmptyTitleCount)
}

function Invoke-SemanticChecksCollect {
    # 收集语义闸门的判定结果，不写全局计数（供离线自证使用）。
    param([Parameter(Mandatory)]$Analysis)
    $list = [System.Collections.Generic.List[object]]::new()
    $collector = {
        param([bool]$Condition, [string]$Label, [string]$Detail = '')
        $list.Add([pscustomobject]@{ Ok = [bool]$Condition; Label = $Label; Detail = $Detail }) | Out-Null
    }.GetNewClosure()
    Invoke-SemanticChecks -Analysis $Analysis -Assert $collector
    return @($list)
}

function Resolve-ExpectedRowsPolicy {
    # 行数口径解析。0 / 负数不再等于「只要求非空」——那必须显式 -AnyRowCount；
    # 环境变量 PATROL_BITABLE_EXPECTED_ROWS 覆盖到 0 一律报错，不静默放行。
    # 任何模式下都强制行数下限 MinRows >= 1（只要求非空 ≠ 允许 0 行）。
    param(
        [int]$ParameterValue = 78,
        [string]$EnvValue = '',
        [bool]$AnyRowCount = $false,
        [int]$MinRows = 1
    )
    $expected = $ParameterValue
    $source = '参数 -ExpectedRows'
    if (-not [string]::IsNullOrWhiteSpace($EnvValue)) {
        $parsed = 0
        if (-not [int]::TryParse($EnvValue.Trim(), [ref]$parsed)) {
            return [pscustomobject]@{
                Ok = $false; Mode = ''; Expected = 0; MinRows = $MinRows; Source = '环境变量 PATROL_BITABLE_EXPECTED_ROWS'
                Error = ("环境变量 PATROL_BITABLE_EXPECTED_ROWS 不是整数：'{0}'" -f $EnvValue)
            }
        }
        $expected = $parsed
        $source = '环境变量 PATROL_BITABLE_EXPECTED_ROWS'
    }
    if ($MinRows -lt 1) {
        return [pscustomobject]@{
            Ok = $false; Mode = ''; Expected = $expected; MinRows = $MinRows; Source = $source
            Error = ("MinRows 必须 >= 1（行数下限），实际 {0}" -f $MinRows)
        }
    }
    if ($AnyRowCount) {
        return [pscustomobject]@{
            Ok = $true; Mode = 'any'; Expected = $expected; MinRows = $MinRows; Source = $source; Error = ''
        }
    }
    if ($expected -lt 1) {
        return [pscustomobject]@{
            Ok = $false; Mode = ''; Expected = $expected; MinRows = $MinRows; Source = $source
            Error = ("{0} 解析为 {1}；「只要求非空」必须显式加 -AnyRowCount（不再静默退化成读到 1 行即过）" -f $source, $expected)
        }
    }
    return [pscustomobject]@{
        Ok = $true; Mode = 'exact'; Expected = $expected; MinRows = $MinRows; Source = $source; Error = ''
    }
}

function Resolve-LiveReadiness {
    # 判定「这一轮该不该真读」以及「读不了时算 SKIP 还是 FAIL」。
    #   · 没要求实跑                -> skip（默认离线档）
    #   · lark-cli 退出码非 0       -> fail（鉴权失败一律判 FAIL，不得算 SKIP）
    #   · auth status 输出解析不了   -> fail（解析失败一律判 FAIL）
    #   · 工具缺失 / user 未就绪     -> skip；-RequireLive 时 -> fail（要求实跑却没实跑）
    param(
        [bool]$DemandLive = $false,
        [bool]$RequireLive = $false,
        [bool]$CliAvailable = $false,
        [int]$AuthExitCode = 0,
        [bool]$AuthParsed = $true,
        [bool]$UserReady = $false,
        [string]$Detail = ''
    )
    if (-not $DemandLive) {
        return [pscustomobject]@{ Action = 'skip'; Reason = '未给 -Live / -RequireLive（默认离线档：只跑自测）' }
    }
    if (-not $CliAvailable) {
        $reason = '未找到 lark-cli'
        if ($RequireLive) { return [pscustomobject]@{ Action = 'fail'; Reason = ($reason + '；-RequireLive 要求真读') } }
        return [pscustomobject]@{ Action = 'skip'; Reason = $reason }
    }
    if ($AuthExitCode -ne 0) {
        return [pscustomobject]@{
            Action = 'fail'
            Reason = ("lark-cli auth status 失败（exit={0}）；鉴权失败一律判 FAIL，不算 SKIP{1}" -f $AuthExitCode, $(if ($Detail) { "；$Detail" } else { '' }))
        }
    }
    if (-not $AuthParsed) {
        return [pscustomobject]@{
            Action = 'fail'
            Reason = ("lark-cli auth status 输出无法解析；解析失败一律判 FAIL，不算 SKIP{0}" -f $(if ($Detail) { "：$Detail" } else { '' }))
        }
    }
    if (-not $UserReady) {
        $reason = ("lark-cli user 身份未就绪（缺凭据{0}）" -f $(if ($Detail) { "，$Detail" } else { '' }))
        if ($RequireLive) { return [pscustomobject]@{ Action = 'fail'; Reason = ($reason + '；-RequireLive 要求真读') } }
        return [pscustomobject]@{ Action = 'skip'; Reason = $reason }
    }
    return [pscustomobject]@{ Action = 'run'; Reason = '' }
}

function New-FakeRecordListResponse {
    # 离线模拟 lark-cli 的矩阵 JSON；next_offset 故意留空，覆盖真实返回的形状。
    # FieldNames 可换序，用来自证「按表头名取列，列序颠倒也不错列」。
    param(
        [int]$Offset,
        [int]$Limit,
        [int]$Total,
        [switch]$EmptyButMore,
        [string[]]$FieldNames = @('项目名', '巡检间隔(分钟)'),
        [int[]]$Intervals = $null,
        [switch]$EmptyIntervals
    )
    $end = [Math]::Min($Offset + $Limit, $Total)
    if ($EmptyButMore) { $end = $Offset }

    $ids = [System.Collections.Generic.List[string]]::new()
    $matrix = [System.Collections.Generic.List[object]]::new()
    for ($i = $Offset; $i -lt $end; $i++) {
        $ids.Add(("rec_fake_{0}" -f $i))
        $title = "项目 {0}" -f $i
        $interval = if ($EmptyIntervals) { '' } elseif ($null -ne $Intervals) { [int]$Intervals[$i % $Intervals.Count] } else { [int]($i + 1) }
        $cells = @()
        foreach ($fn in $FieldNames) {
            if ($fn -eq '项目名') { $cells += $title }
            elseif ($fn -eq '巡检间隔(分钟)') { $cells += $interval }
            else { $cells += '' }
        }
        $matrix.Add($cells)
    }
    $hasMore = ($end -lt $Total) -or $EmptyButMore
    $data = [ordered]@{
        fields          = @($FieldNames)
        data            = @($matrix)
        record_id_list  = @($ids)
        has_more        = $hasMore
        next_offset     = ''
    }
    $json = [ordered]@{ ok = $true; data = $data } | ConvertTo-Json -Depth 10 -Compress
    return [pscustomobject]@{ ExitCode = 0; Output = $json }
}

function New-FakeInvoker {
    # MaxRowsPerPage > 0 时模拟「服务端每页少返几行」——旧口径的「每页必满」会在这里假红。
    param(
        [int]$Total,
        [switch]$EmptyButMore,
        [int]$MaxRowsPerPage = 0,
        [string[]]$FieldNames = @('项目名', '巡检间隔(分钟)'),
        [int[]]$Intervals = $null,
        [switch]$EmptyIntervals
    )
    return {
        param($cli, $cliArgs)
        $offset = [int](Get-CliArgValue -CliArgs $cliArgs -Name '--offset' -Default '0')
        $limit = [int](Get-CliArgValue -CliArgs $cliArgs -Name '--limit' -Default '2')
        if ($MaxRowsPerPage -gt 0 -and $limit -gt $MaxRowsPerPage) { $limit = $MaxRowsPerPage }
        New-FakeRecordListResponse -Offset $offset -Limit $limit -Total $Total -EmptyButMore:$EmptyButMore `
            -FieldNames $FieldNames -Intervals $Intervals -EmptyIntervals:$EmptyIntervals
    }.GetNewClosure()
}

function New-FakeRow {
    # 离线用的行（与 Read-BitableRowsPaged 产出的行同形）。
    param([string]$Id, [Parameter(Mandatory)]$Values)
    return [pscustomobject]@{ record_id = $Id; values = @($Values) }
}

# ---------------------------------------------------------------------------
# 离线自测 A：分页边界 + lark-cli 非零退出（原有失败面，保留）
# ---------------------------------------------------------------------------
$normal = Read-BitableRowsPaged -BaseToken 'fake' -TableId 'tblfake' -LarkCli 'fake' -PageSize 2 -Invoke (New-FakeInvoker -Total 5)
Assert-True ($normal.Rows.Count -eq 5) 'selftest pagination: 5 rows collected across pages' ("actual={0}" -f $normal.Rows.Count)
Assert-True (($normal.PageOffsets -join ',') -eq '0,2,4') 'selftest pagination: offsets 0,2,4' ("actual={0}" -f ($normal.PageOffsets -join ','))
Assert-True ($normal.Pages -eq 3) 'selftest pagination: 3 pages' ("actual={0}" -f $normal.Pages)

$stallMessage = ''
try {
    $null = Read-BitableRowsPaged -BaseToken 'fake' -TableId 'tblfake' -LarkCli 'fake' -PageSize 2 -Invoke (New-FakeInvoker -Total 5 -EmptyButMore)
}
catch { $stallMessage = $_.Exception.Message }
Assert-True ($stallMessage -match 'did not advance|分页未前进') 'selftest pagination: stalled offset is a hard error' $stallMessage

$exitMessage = ''
$boom = { param($cli, $cliArgs) [pscustomobject]@{ ExitCode = 23; Output = 'mock permission denied' } }
try {
    $null = Read-BitableRowsPaged -BaseToken 'fake' -TableId 'tblfake' -LarkCli 'fake' -PageSize 2 -Invoke $boom
}
catch { $exitMessage = $_.Exception.Message }
Assert-True ($exitMessage -match 'exit=23') 'selftest lark-cli: nonzero exit surfaces exit=23' $exitMessage

# 真实启动器也验一次：.cmd 退出 23，Invoke-LarkCliCapture 必须拿到 23。
$tempCmd = Join-Path $env:TEMP ("patrol-bitable-live-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
try {
    [System.IO.File]::WriteAllText($tempCmd, "@echo off`r`nexit /b 23`r`n", [System.Text.Encoding]::ASCII)
    $capture = Invoke-LarkCliCapture -FilePath $tempCmd -ArgumentList @()
    Assert-True ($capture.ExitCode -eq 23) 'selftest lark-cli: launcher captures process exit code' ("actual={0}" -f $capture.ExitCode)
}
finally {
    Remove-Item -LiteralPath $tempCmd -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 离线自测 B：页数只按「上限 / 无空页 / 逐页自洽」判，不写死「每页必满」
# ---------------------------------------------------------------------------
$shortPage = Read-BitableRowsPaged -BaseToken 'fake' -TableId 'tblfake' -LarkCli 'fake' -PageSize 50 -MaxPages 200 `
    -Invoke (New-FakeInvoker -Total 30 -MaxRowsPerPage 10)
Assert-True ($shortPage.Rows.Count -eq 30) 'selftest page bound: server may return fewer rows per page (rows=30)' ("actual={0}" -f $shortPage.Rows.Count)
Assert-True ($shortPage.Pages -eq 3) 'selftest page bound: 30 rows at 10 per page = 3 pages' ("actual={0}" -f $shortPage.Pages)
Assert-True ($shortPage.Pages -le $shortPage.Rows.Count) 'selftest page bound: pages <= rows (no empty page)' ("pages={0} rows={1}" -f $shortPage.Pages, $shortPage.Rows.Count)
Assert-True ((@($shortPage.PageRowCounts) | Measure-Object -Sum).Sum -eq 30) 'selftest page bound: per-page row counts sum to total rows' ("counts={0}" -f ($shortPage.PageRowCounts -join ','))
Assert-True ([int][Math]::Ceiling(30 / 50.0) -ne $shortPage.Pages) `
    'selftest page bound: the old "every page must be full" rule would have turned red here' `
    ("ceil(rows/pageSize)={0} actualPages={1}" -f [int][Math]::Ceiling(30 / 50.0), $shortPage.Pages)

# ---------------------------------------------------------------------------
# 离线自测 C：内容语义（空洞 1）与按表头名取列（空洞 4）
# ---------------------------------------------------------------------------
$zeroAnalysis = Get-BitableRowSemantics -FieldNames @('项目名', '巡检间隔(分钟)') -Rows @(
    (New-FakeRow -Id 'rec_zero_1' -Values @('停跑甲', 0)),
    (New-FakeRow -Id 'rec_zero_2' -Values @('停跑乙', ''))
)
$zeroChecks = Invoke-SemanticChecksCollect -Analysis $zeroAnalysis
$zeroActive = @($zeroChecks | Where-Object { $_.Label -like '*at least one active row*' })
Assert-True (($zeroActive.Count -eq 1) -and (-not $zeroActive[0].Ok)) `
    'selftest semantics: an all-disabled table must turn the active-row check red' `
    ("active={0} disabled={1}" -f $zeroAnalysis.ActiveCount, $zeroAnalysis.DisabledCount)
Assert-True ($zeroAnalysis.ActiveCount -eq 0) 'selftest semantics: all-disabled table has zero active rows' ("actual={0}" -f $zeroAnalysis.ActiveCount)

$mixedAnalysis = Get-BitableRowSemantics -FieldNames @('项目名', '巡检间隔(分钟)') -Rows @(
    (New-FakeRow -Id 'rec_mixed_1' -Values @('在跑甲', 360)),
    (New-FakeRow -Id 'rec_mixed_2' -Values @('停跑乙', 0)),
    (New-FakeRow -Id 'rec_mixed_3' -Values @('停跑丙', ''))
)
$mixedChecks = Invoke-SemanticChecksCollect -Analysis $mixedAnalysis
$mixedActive = @($mixedChecks | Where-Object { $_.Label -like '*at least one active row*' })
Assert-True (($mixedActive.Count -eq 1) -and $mixedActive[0].Ok) `
    'selftest semantics: a table with one active row keeps the active-row check green' `
    ("active={0} disabled={1}" -f $mixedAnalysis.ActiveCount, $mixedAnalysis.DisabledCount)
Assert-True ($mixedAnalysis.ActiveCount -eq 1) 'selftest semantics: exactly one active row is counted' ("actual={0}" -f $mixedAnalysis.ActiveCount)

$noTitleAnalysis = Get-BitableRowSemantics -FieldNames @('项目名', '巡检间隔(分钟)') -Rows @(
    (New-FakeRow -Id 'rec_notitle_1' -Values @('在跑甲', 60)),
    (New-FakeRow -Id 'rec_notitle_2' -Values @('   ', 60))
)
$noTitleChecks = Invoke-SemanticChecksCollect -Analysis $noTitleAnalysis
$noTitleCheck = @($noTitleChecks | Where-Object { $_.Label -like '*every active row has a non-empty title*' })
Assert-True (($noTitleCheck.Count -eq 1) -and (-not $noTitleCheck[0].Ok)) `
    'selftest semantics: an active row without a title must turn the title check red' `
    ("bad={0}" -f ($noTitleAnalysis.ActiveWithoutTitleIds -join ','))

# 列序颠倒：位置会读错，按表头名不会。
$reversedFields = @('巡检间隔(分钟)', '项目名')
$reversedAnalysis = Get-BitableRowSemantics -FieldNames $reversedFields -Rows @(
    (New-FakeRow -Id 'rec_rev_1' -Values @(360, 'OpenEyes'))
)
Assert-True ($reversedAnalysis.ActiveCount -eq 1) `
    'selftest columns: reversed column order still finds the active row by header name' `
    ("active={0}" -f $reversedAnalysis.ActiveCount)
Assert-True (($reversedAnalysis.ActiveTitles.Count -eq 1) -and ($reversedAnalysis.ActiveTitles[0] -eq 'OpenEyes')) `
    'selftest columns: reversed column order still resolves the title by header name' `
    ("titles={0}" -f ($reversedAnalysis.ActiveTitles -join '|'))

$reversedTable = Read-BitableRowsPaged -BaseToken 'fake' -TableId 'tblfake' -LarkCli 'fake' -PageSize 50 `
    -Invoke (New-FakeInvoker -Total 2 -FieldNames $reversedFields -Intervals @(360, 0))
$reversedNamed = @(ConvertFrom-BitableRowSet -FieldNames $reversedTable.Fields -Rows $reversedTable.Rows)
$reversedItems = @($reversedNamed | ForEach-Object { Convert-BitableRowToItem -Row $_ })
Assert-True (($reversedItems.Count -eq 2) -and ($reversedItems[0].title -eq '项目 0') -and ($reversedItems[0].intervalMin -eq 360)) `
    'selftest columns: reversed table still normalizes title/interval correctly through the adapter' `
    ("title0='{0}' interval0={1}" -f $reversedItems[0].title, $reversedItems[0].intervalMin)

$missingAnalysis = Get-BitableRowSemantics -FieldNames @('项目名', '别名列') -Rows @(
    (New-FakeRow -Id 'rec_miss_1' -Values @('在跑甲', 60))
)
$missingChecks = Invoke-SemanticChecksCollect -Analysis $missingAnalysis
$missingCheck = @($missingChecks | Where-Object { $_.Label -like '*required columns present*' })
Assert-True (($missingAnalysis.MissingFields -contains '巡检间隔(分钟)') -and ($missingCheck.Count -eq 1) -and (-not $missingCheck[0].Ok)) `
    'selftest columns: a missing header is named and turns the check red' `
    ("missing={0}" -f ($missingAnalysis.MissingFields -join ','))

# ---------------------------------------------------------------------------
# 离线自测 D：行数口径策略（空洞 2）
# ---------------------------------------------------------------------------
$policyEnvZero = Resolve-ExpectedRowsPolicy -ParameterValue 78 -EnvValue '0' -AnyRowCount:$false -MinRows 1
Assert-True (-not $policyEnvZero.Ok) 'selftest policy: env override to 0 is an error, not a silent pass' $policyEnvZero.Error
$policyEnvZeroAllowed = Resolve-ExpectedRowsPolicy -ParameterValue 78 -EnvValue '0' -AnyRowCount:$true -MinRows 1
Assert-True ($policyEnvZeroAllowed.Ok -and ($policyEnvZeroAllowed.Mode -eq 'any') -and ($policyEnvZeroAllowed.MinRows -eq 1)) `
    'selftest policy: env 0 is accepted only with the explicit -AnyRowCount switch' `
    ("mode={0} minRows={1}" -f $policyEnvZeroAllowed.Mode, $policyEnvZeroAllowed.MinRows)
$policyEnvBad = Resolve-ExpectedRowsPolicy -ParameterValue 78 -EnvValue 'abc' -AnyRowCount:$false -MinRows 1
Assert-True (-not $policyEnvBad.Ok) 'selftest policy: a non-numeric env override is an error' $policyEnvBad.Error
$policyParamZero = Resolve-ExpectedRowsPolicy -ParameterValue 0 -EnvValue '' -AnyRowCount:$false -MinRows 1
Assert-True (-not $policyParamZero.Ok) 'selftest policy: -ExpectedRows 0 without -AnyRowCount is an error' $policyParamZero.Error
$policyDefault = Resolve-ExpectedRowsPolicy -ParameterValue 78 -EnvValue '' -AnyRowCount:$false -MinRows 1
Assert-True ($policyDefault.Ok -and ($policyDefault.Mode -eq 'exact') -and ($policyDefault.Expected -eq 78)) `
    'selftest policy: the default is an exact match against 78 rows' `
    ("mode={0} expected={1}" -f $policyDefault.Mode, $policyDefault.Expected)
$policyBadFloor = Resolve-ExpectedRowsPolicy -ParameterValue 78 -EnvValue '' -AnyRowCount:$true -MinRows 0
Assert-True (-not $policyBadFloor.Ok) 'selftest policy: MinRows 0 is an error (a row floor is mandatory)' $policyBadFloor.Error

# ---------------------------------------------------------------------------
# 离线自测 E：SKIP / FAIL 分档（空洞 3）
# ---------------------------------------------------------------------------
$readyNone = Resolve-LiveReadiness -DemandLive $false
Assert-True ($readyNone.Action -eq 'skip') 'selftest readiness: no -Live means skip, not fail' $readyNone.Reason
$readyRequireNoCli = Resolve-LiveReadiness -DemandLive $true -RequireLive $true -CliAvailable $false
Assert-True ($readyRequireNoCli.Action -eq 'fail') 'selftest readiness: -RequireLive without lark-cli must fail, not skip' $readyRequireNoCli.Reason
$readyLiveNoCli = Resolve-LiveReadiness -DemandLive $true -RequireLive $false -CliAvailable $false
Assert-True ($readyLiveNoCli.Action -eq 'skip') 'selftest readiness: -Live without lark-cli skips (environment not ready)' $readyLiveNoCli.Reason
$readyAuthFail = Resolve-LiveReadiness -DemandLive $true -RequireLive $false -CliAvailable $true -AuthExitCode 1 -AuthParsed $true -UserReady $false
Assert-True ($readyAuthFail.Action -eq 'fail') 'selftest readiness: auth failure (nonzero exit) must fail, never skip' $readyAuthFail.Reason
$readyAuthParseFail = Resolve-LiveReadiness -DemandLive $true -RequireLive $false -CliAvailable $true -AuthExitCode 0 -AuthParsed $false -UserReady $false
Assert-True ($readyAuthParseFail.Action -eq 'fail') 'selftest readiness: unparsable auth output must fail, never skip' $readyAuthParseFail.Reason
$readyNotReady = Resolve-LiveReadiness -DemandLive $true -RequireLive $false -CliAvailable $true -AuthExitCode 0 -AuthParsed $true -UserReady $false
Assert-True ($readyNotReady.Action -eq 'skip') 'selftest readiness: missing credentials skip under -Live' $readyNotReady.Reason
$readyNotReadyStrict = Resolve-LiveReadiness -DemandLive $true -RequireLive $true -CliAvailable $true -AuthExitCode 0 -AuthParsed $true -UserReady $false
Assert-True ($readyNotReadyStrict.Action -eq 'fail') 'selftest readiness: missing credentials fail under -RequireLive' $readyNotReadyStrict.Reason
$readyRun = Resolve-LiveReadiness -DemandLive $true -RequireLive $true -CliAvailable $true -AuthExitCode 0 -AuthParsed $true -UserReady $true
Assert-True ($readyRun.Action -eq 'run') 'selftest readiness: a ready environment runs the live read' $readyRun.Reason

# ---------------------------------------------------------------------------
# 行数口径策略：先定策略，再决定能不能真读
# ---------------------------------------------------------------------------
$policy = Resolve-ExpectedRowsPolicy -ParameterValue $ExpectedRows -EnvValue $expectedRowsEnvRaw `
    -AnyRowCount:$AnyRowCount.IsPresent -MinRows $MinRows
$policyOk = $policy.Ok
if ($policyOk) {
    Write-Host ("policy: mode={0} expected={1} minRows={2} source={3}" -f $policy.Mode, $policy.Expected, $policy.MinRows, $policy.Source)
}
else {
    Write-Fail 'row-count policy' $policy.Error
}

# ---------------------------------------------------------------------------
# live 段：默认 SKIP；-Live 真读；-RequireLive 要求真读且必须成功
# ---------------------------------------------------------------------------
if (-not $policyOk) {
    Write-Fail 'live bitable read' '行数口径策略非法，未做实跑'
}
elseif (-not $Live -and -not $RequireLive) {
    Write-Skip 'live bitable read' '未给 -Live / -RequireLive（默认离线档：自测已跑，真读由人工触发）'
}
else {
    $cliAvailable = ($null -ne (Get-Command -Name $LarkCli -ErrorAction SilentlyContinue))
    $authExitCode = 0
    $authParsed = $true
    $userReady = $false
    $authDetail = ''
    if ($cliAvailable) {
        $auth = Invoke-LarkCliCapture -FilePath $LarkCli -ArgumentList @('auth', 'status', '--json')
        $authExitCode = $auth.ExitCode
        if ($authExitCode -eq 0) {
            try {
                $authJson = ConvertFrom-LarkJson -Text $auth.Output
                $identities = $authJson['identities']
                $user = if ($identities -is [System.Collections.IDictionary]) { $identities['user'] } else { $null }
                $userReady = ($null -ne $user) -and ([bool]$user['available']) -and ([string]$user['status'] -eq 'ready')
                $authDetail = ("status={0}, tokenStatus={1}" -f `
                    $(if ($null -ne $user) { [string]$user['status'] } else { 'missing' }), `
                    $(if ($null -ne $user) { [string]$user['tokenStatus'] } else { 'missing' }))
            }
            catch {
                $authParsed = $false
                $authDetail = $_.Exception.Message
            }
        }
        else {
            $authDetail = (Get-FirstOutputLine -Text ([string]$auth.Output))
        }
    }
    $readiness = Resolve-LiveReadiness -DemandLive $true -RequireLive $RequireLive.IsPresent -CliAvailable $cliAvailable `
        -AuthExitCode $authExitCode -AuthParsed $authParsed -UserReady $userReady -Detail $authDetail
    if ($readiness.Action -eq 'skip') {
        Write-Skip 'live bitable read' $readiness.Reason
    }
    elseif ($readiness.Action -eq 'fail') {
        Write-Fail 'live bitable read' $readiness.Reason
    }
    else {
        try {
            Write-Host ("live: lark-cli base +record-list --table-id {0} --limit {1} --as user（只读）" -f $TableId, $PageSize)
            $result = Read-BitableRowsPaged -BaseToken $BaseToken -TableId $TableId -LarkCli $LarkCli -PageSize $PageSize -MaxPages $MaxPages
            Write-Host ("live: rows={0} fields={1} pages={2} offsets={3}" -f `
                $result.Rows.Count, $result.Fields.Count, $result.Pages, ($result.PageOffsets -join ','))

            Assert-True ($result.Fields.Count -gt 0) 'live: fields returned' ("fields={0}" -f $result.Fields.Count)
            foreach ($required in @('项目名', '巡检间隔(分钟)')) {
                Assert-True ($result.Fields -contains $required) ("live: field present by header name: {0}" -f $required) `
                    ("fields={0}" -f ($result.Fields -join '|'))
            }

            # 行数：精确档比对期望值；宽松档只认下限（下限恒 >= 1，不许读到 0 行就算过）。
            if ($policy.Mode -eq 'exact') {
                Assert-True ($result.Rows.Count -eq $policy.Expected) ("live: row count == {0}" -f $policy.Expected) ("actual={0}" -f $result.Rows.Count)
            }
            Assert-True ($result.Rows.Count -ge $policy.MinRows) ("live: row count >= {0} (row floor)" -f $policy.MinRows) ("actual={0}" -f $result.Rows.Count)

            # 页数：只判「有页 / 不超上限 / 无空页 / 逐页自洽 / 偏移递增」，不写死每页必满。
            $offsets = @($result.PageOffsets)
            $ascending = $true
            for ($i = 1; $i -lt $offsets.Count; $i++) { if ($offsets[$i] -le $offsets[$i - 1]) { $ascending = $false } }
            Assert-True ($result.Pages -ge 1) 'live: at least one page fetched' ("pages={0}" -f $result.Pages)
            Assert-True ($result.Pages -le $MaxPages) 'live: page count within the MaxPages upper bound' ("pages={0} max={1}" -f $result.Pages, $MaxPages)
            Assert-True ($result.Pages -le $result.Rows.Count) 'live: no empty page (pages <= rows)' ("pages={0} rows={1}" -f $result.Pages, $result.Rows.Count)
            Assert-True ((@($result.PageRowCounts) | Measure-Object -Sum).Sum -eq $result.Rows.Count) `
                'live: per-page row counts sum to total rows' ("counts={0}" -f ($result.PageRowCounts -join ','))
            Assert-True $ascending 'live: page offsets strictly increasing' ("offsets={0}" -f ($offsets -join ','))

            # 内容语义：必须真的有在跑行，且在跑行必须有标题。
            $analysis = Get-BitableRowSemantics -FieldNames $result.Fields -Rows $result.Rows
            Invoke-SemanticChecks -Analysis $analysis -Assert ${function:Assert-True}

            $rows = @(ConvertFrom-BitableRowSet -FieldNames $result.Fields -Rows $result.Rows)
            Assert-True ($rows.Count -eq $result.Rows.Count) 'live: matrix rows converted to objects' ("rows={0}" -f $rows.Count)

            $items = [System.Collections.Generic.List[object]]::new()
            $normalizeErrors = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $row = $rows[$i]
                $raw = $result.Rows[$i]
                try {
                    $item = Convert-BitableRowToItem -Row $row
                    if (-not $item.id) { throw '归一后 id 为空' }
                    if ($item.id -ne [string]$raw.record_id) { throw '归一后 id 与 record_id 不一致' }
                    if ($item.priority -notin @('P0', 'P1', 'P2')) { throw ("priority 非法：{0}" -f $item.priority) }
                    if ($item.intervalMin -isnot [int]) { throw ("intervalMin 不是 int：{0}" -f $item.intervalMin.GetType().Name) }
                    # 按表头名回查：归一结果必须与「按名字取到的原值」一致，否则说明列被错位贴值了。
                    $rawTitle = ([string](Get-FieldValueByName -FieldNames $result.Fields -Values @($raw.values) -Name '项目名')).Trim()
                    $rawInterval = Get-FieldValueByName -FieldNames $result.Fields -Values @($raw.values) -Name '巡检间隔(分钟)'
                    $expectInterval = 0
                    if ($null -ne $rawInterval) {
                        try {
                            $numeric = [double]$rawInterval
                            if (-not [double]::IsNaN($numeric) -and -not [double]::IsInfinity($numeric) -and $numeric -gt 0) {
                                $expectInterval = [int][math]::Floor($numeric)
                            }
                        }
                        catch { $expectInterval = 0 }
                    }
                    if ($item.title -ne $rawTitle) { throw ("按表头名回查 title 不一致：item='{0}' 原始='{1}'" -f $item.title, $rawTitle) }
                    if ($item.intervalMin -ne $expectInterval) { throw ("按表头名回查 intervalMin 不一致：item={0} 原始={1}" -f $item.intervalMin, $expectInterval) }
                    $items.Add($item) | Out-Null
                }
                catch {
                    if ($normalizeErrors.Count -lt 5) { $normalizeErrors.Add($_.Exception.Message) }
                }
            }
            Assert-True ($items.Count -eq $rows.Count) 'live: every row normalized via Convert-BitableRowToItem' `
                ("ok={0}/{1}; first errors: {2}" -f $items.Count, $rows.Count, ($normalizeErrors -join ' | '))

            $contractOk = 0
            $contractErrors = [System.Collections.Generic.List[string]]::new()
            foreach ($item in $items) {
                try {
                    $contract = ConvertTo-PatrolItem -Item $item
                    if (-not $contract.id -or -not $contract.title) { throw '契约 item 缺 id/title' }
                    $contractOk++
                }
                catch {
                    if ($contractErrors.Count -lt 5) { $contractErrors.Add($_.Exception.Message) }
                }
            }
            Assert-True ($contractOk -eq $items.Count) 'live: every normalized item passes ConvertTo-PatrolItem' `
                ("ok={0}/{1}; first errors: {2}" -f $contractOk, $items.Count, ($contractErrors -join ' | '))

            $disabled = @($items | Where-Object { $_.intervalMin -eq 0 }).Count
            $active = $items.Count - $disabled
            Write-Host ("live: normalized={0} activeInterval={1} disabledInterval={2} emptyTitle={3} distinctIds={4}" -f `
                $items.Count, $active, $disabled, $analysis.EmptyTitleCount, $result.Rows.Count)
            Write-Host ("live: active rows ({0}): {1}" -f $active, (($analysis.ActiveTitles | Select-Object -First 10) -join ' / '))
            if ($analysis.EmptyTitleCount -gt 0) {
                Write-Host ("live: empty-title rows ({0}): {1}" -f $analysis.EmptyTitleCount, (($analysis.EmptyTitleIds | Select-Object -First 5) -join ','))
            }
        }
        catch {
            Write-Fail 'live bitable read' $_.Exception.Message
        }
    }
}

# -RequireLive：任何 SKIP 都判 FAIL（要求实跑就必须真跑到）。
if ($RequireLive -and $script:Skip -gt 0) {
    Write-Fail 'require-live' ("-RequireLive 要求真读成功，但本轮有 {0} 项 SKIP" -f $script:Skip)
}

Write-Host ("summary pass={0} skip={1} fail={2}" -f $script:Pass, $script:Skip, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
