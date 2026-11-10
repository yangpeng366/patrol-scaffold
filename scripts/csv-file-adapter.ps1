#requires -Version 7
<#
.SYNOPSIS
  csv-file-adapter.ps1 — provider=csv-file 的源适配器（第1层 Source Adapter）。

.DESCRIPTION
  数据源 = 一个本地 CSV 文件，一行一个任务方向。零网络、零凭据、零依赖，
  与 local-json 同一把尺子：list-items() / write-back() / resolve-name()。
  下游（调度器 / worker / 关联器 / 输出 / 看门狗）与 patrol-loop.ps1 一行不改。

  契约要点：
    - 解析只用 Import-Csv（-Encoding utf8）。引号内逗号、引号内换行、CRLF/LF 混排、
      空行/纯空白行都由它处理，不手写 split。
    - 列映射可配置：columnMap = "id=编号;title=项目名;priority=优先级;interval=间隔;
      status=状态;action=动作;note=备注"（未写的键按同名列回退）。
    - 必填列（id/title/priority/interval）缺失 -> 抛错并点名缺哪列，绝不静默当空。
    - write-back 只改「目标行 + 指定列」：记录边界按 RFC4180 引号规则定位，其余行的
      原始字节（含引号风格与各自的行尾）原样拼回；落盘 UTF-8 无 BOM。

.NOTES
  配置项见 adapters/csv-file.adapter.json；11 节规格见 references/csv-file-adapter.md。
#>

# 统一无 BOM UTF-8（退化写法，与 local-json-adapter.ps1 一致）
$script:CsvNoBom = [System.Text.UTF8Encoding]::new($false)
$script:CsvRepoRoot = Split-Path -Parent $PSScriptRoot
$script:CsvKeys = @('id', 'title', 'priority', 'interval', 'status', 'action', 'note')
$script:CsvRequiredKeys = @('id', 'title', 'priority', 'interval')

function Resolve-PatrolCsvColumnMap {
    # columnMap 规格串 -> 有序字典（canonical key -> 实际列名）
    param([string]$ColumnMap)
    $map = [ordered]@{}
    foreach ($k in $script:CsvKeys) { $map[$k] = $k }
    if ([string]::IsNullOrWhiteSpace($ColumnMap)) { return $map }
    foreach ($pair in ($ColumnMap -split ';')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $kv = $pair.Split('=', 2)
        if ($kv.Count -ne 2) {
            throw ("csv-file: columnMap 片段 '{0}' 不是 key=列名 形式（示例 id=编号;title=项目名）" -f $pair.Trim())
        }
        $key = $kv[0].Trim().ToLowerInvariant()
        if ($key -eq 'intervalmin') { $key = 'interval' }
        $col = $kv[1].Trim()
        if ($script:CsvKeys -notcontains $key) {
            throw ("csv-file: columnMap 键 '{0}' 不可识别，允许：{1}" -f $kv[0].Trim(), ($script:CsvKeys -join '/'))
        }
        if (-not $col) { throw ("csv-file: columnMap 键 '{0}' 的列名为空" -f $key) }
        $map[$key] = $col
    }
    return $map
}

function Resolve-PatrolCsvPath {
    # 装配层总会注入 tasksFile（它是 provider 无关的通用键）；csv-file 只在它以 .csv
    # 结尾时才采纳，否则用自己 config 里的 csvPath。避免把别家 provider 的样本当 CSV 解析。
    param([string]$CsvPath, [string]$TasksFile)
    $chosen = ''
    $tasks = [string]$TasksFile
    if ($tasks -and $tasks -notmatch '^\$\{') {
        if ($tasks -match '(?i)\.csv$') { $chosen = $tasks }
        else {
            Write-Warning ("csv-file: 忽略 tasksFile='{0}'（不是 .csv；该键由装配层统一注入，别的 provider 用它指 JSON 等源），改用 csvPath" -f $tasks)
        }
    }
    if (-not $chosen) {
        $csv = [string]$CsvPath
        if ($csv -and $csv -notmatch '^\$\{') { $chosen = $csv }
    }
    if (-not $chosen) {
        throw 'csv-file: 未指定 CSV 数据源（-CsvPath <file.csv>、-TasksFile <file.csv>，或环境变量 PATROL_CSV_FILE_CSVPATH）'
    }
    if ([System.IO.Path]::IsPathRooted($chosen)) { return $chosen }
    $repoRel = Join-Path $script:CsvRepoRoot $chosen
    if (Test-Path -LiteralPath $repoRel) { return $repoRel }
    return (Join-Path (Get-Location).Path $chosen)
}

function Read-PatrolCsvText {
    # 原文读入（BOM 由 StreamReader 吃掉），写回时按记录边界拼接用
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw ("csv-file: CSV 文件不存在: {0}" -f $Path) }
    return [System.IO.File]::ReadAllText($Path, $script:CsvNoBom)
}

function Import-PatrolCsvRecord {
    # 解析唯一入口：Import-Csv（显式 -Encoding utf8），不手写 split
    param([Parameter(Mandatory)][string]$Path)
    try {
        return @(Import-Csv -LiteralPath $Path -Encoding utf8)
    }
    catch {
        throw ("csv-file: Import-Csv 解析失败（{0}）：{1}" -f $Path, $_.Exception.Message)
    }
}

function Get-PatrolCsvHeaderMap {
    # 解析列名 -> 实际表头；必填列缺失时点名报错
    param([Parameter(Mandatory)]$Records, [Parameter(Mandatory)]$ColumnMap)
    $headers = @($Records[0].PSObject.Properties.Name)
    $trimmed = @{}
    foreach ($h in $headers) {
        $t = ([string]$h).Trim()
        if (-not $t) { throw 'csv-file: 表头存在空列名，无法做列映射' }
        $lower = $t.ToLowerInvariant()
        if ($trimmed.ContainsKey($lower)) {
            throw ("csv-file: 表头列名重复（忽略大小写与首尾空格）: '{0}'" -f $t)
        }
        $trimmed[$lower] = $h
    }
    $resolved = [ordered]@{}
    foreach ($k in $script:CsvKeys) {
        $want = ([string]$ColumnMap[$k]).Trim().ToLowerInvariant()
        $resolved[$k] = if ($trimmed.ContainsKey($want)) { $trimmed[$want] } else { $null }
    }
    $missing = @()
    foreach ($k in $script:CsvRequiredKeys) {
        if ($null -eq $resolved[$k]) {
            $missing += ("{0}（期望列名 '{1}'）" -f $k, $ColumnMap[$k])
        }
    }
    if ($missing.Count -gt 0) {
        $have = @($headers | ForEach-Object { ([string]$_).Trim() }) -join ','
        throw ("csv-file: CSV 缺必填列：{0}；文件现有列：{1}；列名不同请用 columnMap 重映射（id=编号;title=项目名;...）" -f ($missing -join '、'), $have)
    }
    return $resolved
}

function Get-PatrolCsvRecordSpan {
    # 只定位「原始字节区间」，不做字段切分（字段值一律来自 Import-Csv）。
    # 按 RFC4180 引号规则跨过引号内的逗号/换行，返回每条非空记录的 Start/Length/Text。
    param([Parameter(Mandatory)][string]$Text)
    $spans = New-Object System.Collections.Generic.List[object]
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        $start = $i
        $inQuotes = $false
        while ($i -lt $n) {
            $ch = $Text[$i]
            if ($inQuotes) {
                if ($ch -eq '"') {
                    if ((($i + 1) -lt $n) -and ($Text[$i + 1] -eq '"')) { $i += 2; continue }
                    $inQuotes = $false; $i++; continue
                }
                $i++; continue
            }
            if ($ch -eq '"') { $inQuotes = $true; $i++; continue }
            if (($ch -eq "`r") -or ($ch -eq "`n")) { break }
            $i++
        }
        $end = $i
        if (($i -lt $n) -and ($Text[$i] -eq "`r")) {
            $i++
            if (($i -lt $n) -and ($Text[$i] -eq "`n")) { $i++ }
        }
        elseif (($i -lt $n) -and ($Text[$i] -eq "`n")) { $i++ }
        $raw = $Text.Substring($start, $end - $start)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }   # 空行/纯空白行：Import-Csv 同样跳过
        $spans.Add([pscustomobject]@{ Start = $start; Length = $end - $start; Text = $raw })
    }
    return $spans.ToArray()
}

function ConvertTo-PatrolCsvField {
    # 单字段序列化：含分隔符/引号/换行才加引号，引号双写
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    if ($s -match '[",\r\n]') { return ('"' + ($s -replace '"', '""') + '"') }
    return $s
}

function Get-PatrolCsvFieldValue {
    # 按（可能带空格的）表头名取单元格；缺列/短行统一给空串
    param($Record, [string]$Header)
    if (-not $Header) { return '' }
    $v = $Record.$Header
    if ($null -eq $v) { return '' }
    return [string]$v
}

function Get-PatrolItems {
    # list-items(): CSV -> item 数组（规范化由 provider 层 ConvertTo-PatrolItem 收口）
    param(
        [string]$CsvPath = '',
        [string]$TasksFile = '',
        [string]$ColumnMap = ''
    )
    $path = Resolve-PatrolCsvPath -CsvPath $CsvPath -TasksFile $TasksFile
    $records = @(Import-PatrolCsvRecord -Path $path)
    if ($records.Count -eq 0) {
        throw ("csv-file: CSV 为空或只有表头，没有任何数据行: {0}" -f $path)
    }
    $map = Resolve-PatrolCsvColumnMap -ColumnMap $ColumnMap
    $hdr = Get-PatrolCsvHeaderMap -Records $records -ColumnMap $map

    $items = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $rowNo = 1
    foreach ($rec in $records) {
        $rowNo++
        $id = (Get-PatrolCsvFieldValue -Record $rec -Header $hdr['id']).Trim()
        if (-not $id) {
            throw ("csv-file: 第 {0} 条数据行的 id 列为空（列 '{1}'）；空 id 无法续跑与回写" -f $rowNo, $map['id'])
        }
        if (-not $seen.Add($id)) {
            throw ("csv-file: 第 {0} 条数据行的 id '{1}' 与前文重复；请保证 id 唯一" -f $rowNo, $id)
        }
        $title = (Get-PatrolCsvFieldValue -Record $rec -Header $hdr['title']).Trim()
        if (-not $title) { $title = $id }
        $priority = (Get-PatrolCsvFieldValue -Record $rec -Header $hdr['priority']).Trim()
        $intervalRaw = (Get-PatrolCsvFieldValue -Record $rec -Header $hdr['interval']).Trim()
        $interval = 0
        if ($intervalRaw) {
            $parsed = 0
            if (-not [int]::TryParse($intervalRaw, [ref]$parsed)) {
                throw ("csv-file: 第 {0} 条数据行（id={1}）的间隔列值 '{2}' 不是整数" -f $rowNo, $id, $intervalRaw)
            }
            $interval = $parsed
        }
        $items.Add([pscustomobject][ordered]@{
            id           = $id
            title        = $title
            priority     = $priority
            intervalMin  = $interval
            currentStage = (Get-PatrolCsvFieldValue -Record $rec -Header $hdr['status']).Trim()
            nextStep     = (Get-PatrolCsvFieldValue -Record $rec -Header $hdr['action']).Trim()
            description  = (Get-PatrolCsvFieldValue -Record $rec -Header $hdr['note']).Trim()
        })
    }
    return $items.ToArray()
}

function Invoke-PatrolCsvCellUpdate {
    # 写回内核：rowId -> @{ canonicalKey = 新值 }。只重渲命中行，其余行按原字节拼回。
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Updates,
        [string]$ColumnMap = ''
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw ("csv-file: CSV 文件不存在: {0}" -f $Path) }
    $text = Read-PatrolCsvText -Path $Path
    $records = @(Import-PatrolCsvRecord -Path $Path)
    if ($records.Count -eq 0) { throw ("csv-file: 没有数据行，拒绝写回: {0}" -f $Path) }

    $map = Resolve-PatrolCsvColumnMap -ColumnMap $ColumnMap
    $hdr = Get-PatrolCsvHeaderMap -Records $records -ColumnMap $map
    $headerList = @($records[0].PSObject.Properties.Name)
    $spans = @(Get-PatrolCsvRecordSpan -Text $text)
    if ($spans.Count -ne ($records.Count + 1)) {
        throw ("csv-file: 原始记录边界与解析结果不一致（Import-Csv {0} 行 / 原文 {1} 段），拒绝写回以免破坏文件格式" -f $records.Count, ($spans.Count - 1))
    }

    $indexById = @{}
    for ($k = 0; $k -lt $records.Count; $k++) {
        $rid = (Get-PatrolCsvFieldValue -Record $records[$k] -Header $hdr['id']).Trim()
        if ($indexById.ContainsKey($rid)) {
            throw ("csv-file: id '{0}' 在 CSV 中重复，拒绝写回（无法确定改哪一行）" -f $rid)
        }
        $indexById[$rid] = $k
    }

    $missing = @()
    foreach ($rid in @($Updates.Keys)) {
        if (-not $indexById.ContainsKey([string]$rid)) { $missing += [string]$rid }
    }
    if ($missing.Count -gt 0) {
        throw ("csv-file: 写回目标行不存在：{0}" -f ($missing -join ','))
    }

    $edits = New-Object System.Collections.Generic.List[object]
    foreach ($rid in @($Updates.Keys)) {
        $k = $indexById[[string]$rid]
        $span = $spans[$k + 1]
        $rec = $records[$k]
        $patch = $Updates[$rid]
        $cells = New-Object 'System.Collections.Generic.List[string]'
        foreach ($h in $headerList) {
            $canonical = $null
            foreach ($ck in $script:CsvKeys) {
                if ($hdr[$ck] -and ($hdr[$ck] -eq $h)) { $canonical = $ck; break }
            }
            $val = if ($canonical -and $patch.ContainsKey($canonical)) { $patch[$canonical] } else { $rec.$h }
            $cells.Add((ConvertTo-PatrolCsvField -Value $val))
        }
        $newRaw = ($cells -join ',')
        if ($newRaw -cne $span.Text) {
            $edits.Add([pscustomobject]@{ Start = $span.Start; Length = $span.Length; NewText = $newRaw })
        }
    }
    if ($edits.Count -eq 0) { return 0 }

    $sb = [System.Text.StringBuilder]::new($text)
    foreach ($e in @($edits | Sort-Object -Property Start -Descending)) {
        $null = $sb.Remove($e.Start, $e.Length)
        $null = $sb.Insert($e.Start, $e.NewText)
    }
    $newText = $sb.ToString()
    if ($newText -cne $text) {
        Set-Content -LiteralPath $Path -Value $newText -NoNewline -Encoding utf8NoBOM
    }
    return $edits.Count
}

function Save-PatrolItems {
    # write-back(): 契约入口。只写「非空」的 item 字段，避免把源单元格清空。
    #   currentStage -> status 列 / nextStep -> action 列 / achievement -> note 列
    # threadId、lastRun 属运行态，留在 state/patrol-state.json（源不承载运行态）。
    param(
        [string]$CsvPath = '',
        [string]$TasksFile = '',
        [Parameter(Mandatory)]$Items,
        [string]$ColumnMap = ''
    )
    $path = Resolve-PatrolCsvPath -CsvPath $CsvPath -TasksFile $TasksFile
    $updates = @{}
    foreach ($it in @($Items)) {
        $id = ([string]$it.id).Trim()
        if (-not $id) { throw 'csv-file: Save-PatrolItems 收到没有 id 的 item' }
        $patch = @{}
        $stage = [string]$it.currentStage
        if ($stage) { $patch['status'] = $stage }
        $next = [string]$it.nextStep
        if ($next) { $patch['action'] = $next }
        $ach = [string]$it.achievement
        if ($ach) { $patch['note'] = $ach }
        if ($patch.Count -gt 0) { $updates[$id] = $patch }
    }
    if ($updates.Count -eq 0) { return 0 }
    return (Invoke-PatrolCsvCellUpdate -Path $path -Updates $updates -ColumnMap $ColumnMap)
}

function Set-PatrolCsvRowFields {
    # write-back() 的单条便捷封装：按 id 定位，只改给定列（canonical key）
    param(
        [string]$CsvPath = '',
        [string]$TasksFile = '',
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Fields,
        [string]$ColumnMap = ''
    )
    foreach ($k in @($Fields.Keys)) {
        if ($script:CsvKeys -notcontains $k) {
            throw ("csv-file: 字段 '{0}' 不可写，允许：{1}" -f $k, ($script:CsvKeys -join '/'))
        }
    }
    $path = Resolve-PatrolCsvPath -CsvPath $CsvPath -TasksFile $TasksFile
    $updates = @{}
    $updates[$Id] = $Fields
    return (Invoke-PatrolCsvCellUpdate -Path $path -Updates $updates -ColumnMap $ColumnMap)
}

function Resolve-ItemName {
    # resolve-name(): 摘要用可读名
    param($Item)
    return $Item.title
}
