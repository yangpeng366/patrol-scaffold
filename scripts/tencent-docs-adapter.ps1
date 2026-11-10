#requires -Version 7
<#
.SYNOPSIS
  tencent-docs-adapter.ps1 — provider=tencent-docs 的源适配器（腾讯文档 智能表格 / Smartsheet）。

.DESCRIPTION
  契约与 scripts/BitAbleAdapter.ps1、scripts/local-json-adapter.ps1 完全一致：
    Get-PatrolItems   list-items()   读 Smartsheet 记录 -> 统一 item
    Save-PatrolItems  write-back()   本地镜像（永远写）+ 远端 updateRecords（双门才写）
    Resolve-ItemName  resolve-name() 摘要用可读名

  官方接口（docs.qq.com/open/document/app/openapi/v2/smartsheet/）：
    查询记录 POST /openapi/smartbook/v2/files/{fileID}/sheets/{sheetID}
             body {"getRecords":{"offset":0,"limit":100,"viewID":"..."}}
    更新记录 POST 同路径
             body {"updateRecords":{"records":[{"recordID":"r...","values":{...}}]}}
    Header: Access-Token / Client-Id / Open-Id
    令牌：   GET /oauth/v2/app-account-token?client_id&client_secret       （应用级账号）
             GET /oauth/v2/token?...grant_type=refresh_token              （刷新用户令牌）
    fileID： GET /openapi/drive/v2/util/converter?type=2&value=<encodedID>

  凭据只从环境变量读：不落文件、不写日志、不进描述文件、不在异常里回显。
#>

$script:TxNoBom = [System.Text.UTF8Encoding]::new($false)
$script:TxRepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $script:TxTokenCache) { $script:TxTokenCache = @{} }

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

function Get-TxDefaultFieldMap {
    # 列标题默认值：与 references/patrol-blueprint.md 的 Concretization B 同名列
    return @{
        title        = '项目名'
        repoPath     = '仓库路径'
        description  = '简要描述'
        nextStep     = '下一步'
        priority     = '优先级'
        interval     = '巡检间隔(分钟)'
        threadId     = 'codex_thread_id'
        fake         = '假数据模式'
        lastRun      = '最近巡检时间'
        currentStage = '当前阶段'
        achievement  = '外部成就'
    }
}

function Get-TxDefaultFieldKinds {
    # 智能表格每列有固定字段类型；这里只声明写回时需要用到的三种单元格编码
    return @{ interval = 'number'; fake = 'checkbox'; lastRun = 'text' }
}

function Get-TxConfig {
    # 读 provider 配置文件（只放定位信息与列映射；凭据一律走环境变量）
    param([Parameter(Mandatory)][string]$ConfigPath)

    $p = $ConfigPath
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        $c1 = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $p))
        $c2 = [System.IO.Path]::GetFullPath((Join-Path $script:TxRepoRoot $p))
        $p = if (Test-Path -LiteralPath $c1) { $c1 } else { $c2 }
    }
    if (-not (Test-Path -LiteralPath $p)) {
        throw "tencent-docs: 配置文件不存在: $p（用 PATROL_TENCENT_DOCS_CONFIGPATH 或 -ConfigPath 指定；仓内不放凭据）"
    }
    $raw = [System.IO.File]::ReadAllText($p, $script:TxNoBom)
    if (-not $raw.Trim()) { throw "tencent-docs: 配置文件为空: $p" }
    $cfg = $raw | ConvertFrom-Json

    $fields = Get-TxDefaultFieldMap
    if ($cfg.PSObject.Properties['fields'] -and $cfg.fields) {
        foreach ($pr in $cfg.fields.PSObject.Properties) {
            if ($pr.Value) { $fields[$pr.Name] = [string]$pr.Value }
        }
    }
    $kinds = Get-TxDefaultFieldKinds
    if ($cfg.PSObject.Properties['fieldKinds'] -and $cfg.fieldKinds) {
        foreach ($pr in $cfg.fieldKinds.PSObject.Properties) {
            if ($pr.Value) { $kinds[$pr.Name] = [string]$pr.Value }
        }
    }

    $pageSize = 100
    if ($cfg.PSObject.Properties['pageSize'] -and $cfg.pageSize) {
        try { $pageSize = [int]$cfg.pageSize } catch { $pageSize = 100 }
    }
    if ($pageSize -le 0 -or $pageSize -gt 100) { $pageSize = 100 }   # 官方：limit 最大 100

    $apiBase = 'https://docs.qq.com'
    if ($cfg.PSObject.Properties['apiBase'] -and $cfg.apiBase) { $apiBase = [string]$cfg.apiBase }

    $syncBack = $false
    if ($cfg.PSObject.Properties['syncBack']) { $syncBack = [bool]$cfg.syncBack }

    return [pscustomobject]@{
        ConfigPath    = $p
        FileId        = if ($cfg.PSObject.Properties['fileId']) { [string]$cfg.fileId } else { '' }
        EncodedId     = if ($cfg.PSObject.Properties['encodedId']) { [string]$cfg.encodedId } else { '' }
        SheetId       = if ($cfg.PSObject.Properties['sheetId']) { [string]$cfg.sheetId } else { '' }
        ViewId        = if ($cfg.PSObject.Properties['viewId']) { [string]$cfg.viewId } else { '' }
        PageSize      = $pageSize
        ApiBase       = $apiBase
        SyncBack      = $syncBack
        ExcludeStages = @($cfg.excludeStages | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        Fields        = $fields
        FieldKinds    = $kinds
    }
}

# ---------------------------------------------------------------------------
# 鉴权（只读环境变量）
# ---------------------------------------------------------------------------

function Get-TxToken {
    # 三条取令牌路径，优先级：直给令牌 > 刷新令牌 > 应用级账号
    # 缓存按 apiBase 分桶，单进程内复用；令牌不落盘。
    param([Parameter(Mandatory)]$Config, [string]$ApiBase = 'https://docs.qq.com')

    if (-not $script:TxTokenCache) { $script:TxTokenCache = @{} }
    $base = $ApiBase.TrimEnd('/')
    $now = [DateTimeOffset]::UtcNow
    $hit = $script:TxTokenCache[$base]
    if ($hit -and $hit.ExpiresAt -gt $now.AddMinutes(2)) { return $hit }

    $accessToken = $env:TENCENT_DOCS_ACCESS_TOKEN
    if ($accessToken) {
        $openId = $env:TENCENT_DOCS_OPEN_ID
        $clientId = $env:TENCENT_DOCS_CLIENT_ID
        if (-not $openId -or -not $clientId) {
            throw 'tencent-docs: 直给 TENCENT_DOCS_ACCESS_TOKEN 时还需 TENCENT_DOCS_OPEN_ID 与 TENCENT_DOCS_CLIENT_ID（Open-Id / Client-Id 头必需）'
        }
        $tok = [pscustomobject]@{
            AccessToken = $accessToken; OpenId = $openId; ClientId = $clientId
            ExpiresAt   = $now.AddMinutes(30); ApiBase = $base
        }
        $script:TxTokenCache[$base] = $tok
        return $tok
    }

    $cid = $env:TENCENT_DOCS_CLIENT_ID
    $sec = $env:TENCENT_DOCS_CLIENT_SECRET
    if (-not $cid -or -not $sec) {
        throw 'tencent-docs: 缺凭据。设 TENCENT_DOCS_CLIENT_ID + TENCENT_DOCS_CLIENT_SECRET（应用级账号令牌），或 TENCENT_DOCS_ACCESS_TOKEN + TENCENT_DOCS_OPEN_ID + TENCENT_DOCS_CLIENT_ID。凭据只从环境变量读，不写文件、不打印。'
    }

    $refresh = $env:TENCENT_DOCS_REFRESH_TOKEN
    if ($refresh) {
        $uri = '{0}/oauth/v2/token?client_id={1}&client_secret={2}&grant_type=refresh_token&refresh_token={3}' -f `
            $base, [uri]::EscapeDataString($cid), [uri]::EscapeDataString($sec), [uri]::EscapeDataString($refresh)
    } else {
        $uri = '{0}/oauth/v2/app-account-token?client_id={1}&client_secret={2}' -f `
            $base, [uri]::EscapeDataString($cid), [uri]::EscapeDataString($sec)
    }
    try {
        $r = Invoke-RestMethod -Method 'GET' -Uri $uri -TimeoutSec 30 -ErrorAction 'Stop' -Headers @{ 'Accept' = 'application/json' }
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        throw ("tencent-docs: 换取令牌失败（HTTP {0}）。核对 client_id/client_secret、应用审核状态与 scope（应用级账号需 scope.auth.account）；为避免泄密不回显请求地址。" -f $status)
    }
    if (-not $r.access_token) { throw 'tencent-docs: 令牌响应缺 access_token' }
    if (-not $r.user_id) { throw 'tencent-docs: 令牌响应缺 user_id（Open-Id 头必需）' }

    $expires = 1800
    if ($r.expires_in) { try { $expires = [int]$r.expires_in } catch { $expires = 1800 } }
    if ($expires -lt 120) { $expires = 120 }
    $tok = [pscustomobject]@{
        AccessToken = [string]$r.access_token; OpenId = [string]$r.user_id; ClientId = $cid
        ExpiresAt   = $now.AddSeconds($expires - 60); ApiBase = $base
    }
    $script:TxTokenCache[$base] = $tok
    return $tok
}

function Invoke-TxApi {
    # 统一 HTTP 出口：只报 HTTP 码 / ret / msg，绝不回显 URI（含 client_secret）或令牌
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [Parameter(Mandatory)]$Token,
        [string]$ApiBase = 'https://docs.qq.com'
    )
    $uri = $ApiBase.TrimEnd('/') + $Path
    $headers = @{
        'Access-Token' = [string]$Token.AccessToken
        'Client-Id'    = [string]$Token.ClientId
        'Open-Id'      = [string]$Token.OpenId
    }
    $params = @{ Method = $Method; Uri = $uri; Headers = $headers; TimeoutSec = 30; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 12 -Compress
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = 'application/json; charset=utf-8'
    }

    $resp = $null
    try {
        $resp = Invoke-RestMethod @params
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        $safePath = ($Path -split '\?')[0] -replace '/files/[^/]+', '/files/{fileID}'
        throw ("tencent-docs: {0} {1} 失败（HTTP {2}）。排查：access_token 是否过期 / scope 是否含 scope.smartsheet / fileID·sheetID 是否正确" -f $Method, $safePath, $status)
    }
    if ($null -eq $resp) { throw 'tencent-docs: 接口返回空响应' }
    if (-not $resp.PSObject.Properties['ret']) { throw 'tencent-docs: 响应缺 ret 字段（apiBase 是否指向腾讯文档开放平台）' }
    if ([int]$resp.ret -ne 0) { throw ("tencent-docs: ret={0} msg={1}" -f $resp.ret, $resp.msg) }
    return $resp
}

function Resolve-TxFileId {
    # 只给到 docs.qq.com/sheet/DXXXX 链接时，用官方 fileID 转换接口换真 ID
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Token)

    if ($Config.FileId) { return $Config.FileId }
    if (-not $Config.EncodedId) {
        throw 'tencent-docs: 配置缺 fileId（也可给 encodedId：在线表格链接 docs.qq.com/sheet/D... 里 D 开头那段）'
    }
    $resp = Invoke-TxApi -Method 'GET' -Path ('/openapi/drive/v2/util/converter?type=2&value=' + [uri]::EscapeDataString($Config.EncodedId)) `
        -Token $Token -ApiBase $Config.ApiBase
    $fid = [string]$resp.data.fileID
    if (-not $fid) { throw 'tencent-docs: fileID 转换接口未返回 data.fileID' }
    return $fid
}

# ---------------------------------------------------------------------------
# 单元格编解码（智能表格 values）
# ---------------------------------------------------------------------------

function Get-TxMappedCell {
    # 按列映射取单元格原始值（value 以「列标题」为 key）
    param($Values, $FieldMap, [string]$Key)
    if ($null -eq $Values -or $null -eq $FieldMap) { return $null }
    $name = $FieldMap[$Key]
    if (-not $name) { return $null }
    $prop = $Values.PSObject.Properties[$name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function ConvertFrom-TxTime {
    # 兼容三种来源：ISO 字符串 / 毫秒时间戳字符串（官方日期字段样例）/ 其它原样返回
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = ([string]$Value).Trim()
    if (-not $s) { return $null }
    if ($s -match '^\d{12,13}$') {
        return ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s)).ToString('o')
    }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$dto)) {
        return $dto.ToString('o')
    }
    return $s
}

function ConvertFrom-TxCell {
    # 读：文本/链接/图片/提及都是分段数组，数字与布尔是标量
    param($Cell, [string]$Kind = 'text')
    if ($null -eq $Cell) { return '' }
    if ($Kind -eq 'checkbox') {
        if ($Cell -is [bool]) { return [bool]$Cell }
        return (([string]$Cell).Trim().ToLowerInvariant() -in @('true', '1', 'yes', 'on', '是'))
    }
    if ($Kind -eq 'number') {
        $d = 0.0
        if ([double]::TryParse([string]$Cell, [ref]$d)) { return $d }
        return 0
    }
    if ($Kind -eq 'date') { return (ConvertFrom-TxTime -Value $Cell) }
    if ($Cell -is [string]) { return $Cell.Trim() }
    if ($Cell -is [ValueType]) { return [string]$Cell }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($seg in @($Cell)) {
        if ($null -eq $seg) { continue }
        $props = $seg.PSObject.Properties
        if ($props['text']) { $parts.Add([string]$seg.text) }
        elseif ($props['link']) { $parts.Add([string]$seg.link) }
        elseif ($props['url']) { $parts.Add([string]$seg.url) }
        elseif ($seg -is [string] -or $seg -is [ValueType]) { $parts.Add([string]$seg) }
    }
    return (($parts -join "`n").Trim())
}

function ConvertTo-TxCell {
    # 写：文本按官方的分段格式 [{"type":"text","text":"..."}]；数字/布尔给标量；日期给毫秒时间戳字符串
    param($Value, [string]$Kind = 'text')
    if ($null -eq $Value) { return $null }
    if ($Kind -eq 'checkbox') { return [bool]$Value }
    if ($Kind -eq 'number') {
        $d = 0.0
        if (-not [double]::TryParse([string]$Value, [ref]$d)) { return $null }
        if ($d -eq [Math]::Floor($d)) { return [int64]$d }
        return $d
    }
    if ($Kind -eq 'date') {
        $dto = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$dto)) {
            return [string]$dto.ToUnixTimeMilliseconds()
        }
        return $null
    }
    $s = [string]$Value
    if (-not $s) { return $null }
    # 逗号包裹防止单元素数组被函数输出管道展开成裸对象（官方要求 [{"type":"text",...}]）
    return ,([object[]]@(@{ type = 'text'; text = $s }))
}

# ---------------------------------------------------------------------------
# 记录 -> item
# ---------------------------------------------------------------------------

function Convert-TxRecordToItem {
    # 单条记录归一（形状由 provider 层 ConvertTo-PatrolItem 再兜一次底）
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)]$Config)

    $fm = $Config.Fields
    $kinds = $Config.FieldKinds
    $v = $Record.values

    $id = [string]$Record.recordID
    $title = [string](ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'title') -Kind 'text')
    if (-not $title) { $title = $id }

    $priority = ([string](ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'priority') -Kind 'text')).Trim().ToUpperInvariant()

    $interval = 0    # 0/空 = 停跑；与 patrol-schedule.ps1 的停跑口径一致
    $intervalRaw = Get-TxMappedCell -Values $v -FieldMap $fm -Key 'interval'
    if ($null -ne $intervalRaw -and ([string]$intervalRaw).Trim() -ne '') {
        $n = 0
        if ([int]::TryParse(([string]$intervalRaw).Trim(), [ref]$n)) {
            if ($n -lt 0) { $n = 0 }
            $interval = $n
        }
    }

    $fake = $false
    $fakeRaw = Get-TxMappedCell -Values $v -FieldMap $fm -Key 'fake'
    if ($null -ne $fakeRaw) { $fake = [bool](ConvertFrom-TxCell -Cell $fakeRaw -Kind 'checkbox') }

    $threadId = [string](ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'threadId') -Kind 'text')
    $lastRun = ConvertFrom-TxTime -Value (ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'lastRun') -Kind 'text')

    return [pscustomobject]@{
        id           = $id
        title        = $title
        repoPath     = [string](ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'repoPath') -Kind 'text')
        description  = [string](ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'description') -Kind 'text')
        nextStep     = [string](ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'nextStep') -Kind 'text')
        priority     = $priority
        intervalMin  = $interval
        threadId     = if ($threadId) { $threadId } else { $null }
        fake         = $fake
        lastRun      = $lastRun
        currentStage = [string](ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'currentStage') -Kind 'text')
        achievement  = [string](ConvertFrom-TxCell -Cell (Get-TxMappedCell -Values $v -FieldMap $fm -Key 'achievement') -Kind 'text')
    }
}

# ---------------------------------------------------------------------------
# 契约三函数
# ---------------------------------------------------------------------------

function Get-PatrolItems {
    # list-items()：分页读完子表 -> item 数组
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$ApiBase = ''
    )
    $cfg = Get-TxConfig -ConfigPath $ConfigPath
    if ($ApiBase) { $cfg.ApiBase = $ApiBase }
    if (-not $cfg.SheetId) { throw 'tencent-docs: 配置缺 sheetId（在线表格链接 ?tab=BB0000 里的那段）' }

    $token = Get-TxToken -Config $cfg -ApiBase $cfg.ApiBase
    $fileId = Resolve-TxFileId -Config $cfg -Token $token
    if ($fileId -match '[/\\\s]') { throw 'tencent-docs: fileID 含非法字符（形如 300000000$AAAA…）' }

    $path = '/openapi/smartbook/v2/files/{0}/sheets/{1}' -f $fileId, $cfg.SheetId
    $items = New-Object System.Collections.Generic.List[object]
    $offset = 0
    $pages = 0

    while ($true) {
        $pages++
        if ($pages -gt 50) {
            throw ('tencent-docs: 分页超过 50 页（offset={0}），疑似 hasMore/next 异常，先停手人工核对' -f $offset)
        }
        $get = [ordered]@{ offset = $offset; limit = $cfg.PageSize }
        if ($cfg.ViewId) { $get.viewID = $cfg.ViewId }

        $resp = Invoke-TxApi -Method 'POST' -Path $path -Body @{ getRecords = $get } -Token $token -ApiBase $cfg.ApiBase
        $page = $resp.data.getRecords
        if ($null -eq $page) { break }

        foreach ($rec in @($page.records)) {
            if ($null -eq $rec) { continue }
            $item = Convert-TxRecordToItem -Record $rec -Config $cfg
            if ($cfg.ExcludeStages.Count -gt 0 -and ($cfg.ExcludeStages -contains $item.currentStage)) { continue }
            $items.Add($item)
        }

        if (-not $page.hasMore) { break }
        $next = 0
        try { $next = [int]$page.next } catch { $next = 0 }
        if ($next -gt $offset) { $offset = $next } else { $offset = $offset + $cfg.PageSize }
        $total = 0
        try { $total = [int]$page.total } catch { $total = 0 }
        if ($total -gt 0 -and $offset -ge $total) { break }
    }

    # 注：PS 7.6.5 上 @($泛型List) 会抛 Argument types do not match，统一用 ToArray() 返回
    return $items.ToArray()
}

function Resolve-TxMirrorPath {
    param([Parameter(Mandatory)][string]$TasksFile)
    $p = $TasksFile
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        $p = [System.IO.Path]::GetFullPath((Join-Path $script:TxRepoRoot $p))
    }
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $p
}

function Save-PatrolItems {
    # write-back()：
    #   1) 本地镜像永远写（原子替换，不含凭据），供 digest / 复盘
    #   2) 远端 updateRecords 只在「配置 syncBack=true」且「显式 syncBack=true」双门都开时执行
    param(
        [Parameter(Mandatory)][string]$TasksFile,
        [Parameter(Mandatory)]$Items,
        [string]$ConfigPath = '',
        [string]$SyncBack = 'false',
        [string]$ApiBase = ''
    )
    $arr = @($Items)

    $mirror = Resolve-TxMirrorPath -TasksFile $TasksFile
    $json = $arr | ConvertTo-Json -Depth 6 -AsArray
    $tmp = $mirror + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, $script:TxNoBom)
    Move-Item -LiteralPath $tmp -Destination $mirror -Force

    if (-not $ConfigPath) { return $false }
    $cfg = Get-TxConfig -ConfigPath $ConfigPath
    if ($ApiBase) { $cfg.ApiBase = $ApiBase }

    $gateConfig = [bool]$cfg.SyncBack
    $gateExplicit = (([string]$SyncBack).Trim().ToLowerInvariant() -in @('true', '1', 'yes', 'on'))
    if (-not ($gateConfig -and $gateExplicit)) { return $false }
    if (-not $cfg.SheetId) { throw 'tencent-docs: 配置缺 sheetId，无法写回' }

    $token = Get-TxToken -Config $cfg -ApiBase $cfg.ApiBase
    $fileId = Resolve-TxFileId -Config $cfg -Token $token
    $path = '/openapi/smartbook/v2/files/{0}/sheets/{1}' -f $fileId, $cfg.SheetId
    $fm = $cfg.Fields
    $kinds = $cfg.FieldKinds

    $updates = New-Object System.Collections.Generic.List[object]
    foreach ($it in $arr) {
        if (-not $it.id) { continue }
        $pairs = @(
            @{ field = $fm['currentStage']; value = $it.currentStage; kind = 'text' },
            @{ field = $fm['achievement']; value = $it.achievement; kind = 'text' },
            @{ field = $fm['nextStep']; value = $it.nextStep; kind = 'text' },
            @{ field = $fm['threadId']; value = $it.threadId; kind = 'text' },
            @{ field = $fm['lastRun']; value = $it.lastRun; kind = $kinds['lastRun'] }
        )
        $values = [ordered]@{}
        foreach ($pair in $pairs) {
            if (-not $pair.field) { continue }
            if ($null -eq $pair.value -or ([string]$pair.value) -eq '') { continue }
            $cell = ConvertTo-TxCell -Value $pair.value -Kind $pair.kind
            if ($null -ne $cell) { $values[$pair.field] = $cell }
        }
        if ($values.Count -eq 0) { continue }
        $updates.Add([pscustomobject]@{ recordID = [string]$it.id; values = $values })
    }
    if ($updates.Count -eq 0) { return $false }

    $batchSize = 50   # 官方未公布单次批量上限；保守 50/批（见规格「待核实」）
    $updArr = $updates.ToArray()
    $ok = $true
    for ($i = 0; $i -lt $updArr.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize, $updArr.Count) - 1
        $chunk = $updArr[$i..$end]
        try {
            $null = Invoke-TxApi -Method 'POST' -Path $path -Body @{ updateRecords = @{ records = $chunk } } -Token $token -ApiBase $cfg.ApiBase
        } catch {
            Write-Warning ('[tencent-docs] 写回失败 recordID={0}: {1}' -f ($chunk[0].recordID), $_.Exception.Message)
            $ok = $false
        }
    }
    return $ok
}

function Resolve-ItemName {
    # resolve-name()：摘要/关联器用的可读名
    param($Item)
    if ($null -eq $Item) { return '' }
    $t = [string]$Item.title
    if ($t) { return $t }
    return [string]$Item.id
}
