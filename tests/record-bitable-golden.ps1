#requires -Version 7
<#
    tests/record-bitable-golden.ps1 — 重采 bitable 适配器的「真实输出形状」黄金样本（需凭据 / 需网络）

    为什么需要它：tests/verify-bitable-adapter.ps1 原先用手写 PSCustomObject 当输入，
    那是我们**假设**的形状。真实 `lark-cli base +record-list --format json` 给的是矩阵：
      { "ok": true, "identity": "user",
        "data": { "fields": [...], "field_id_list": [...], "field_type_list": [...],
                  "data": [[cell, cell, ...], ...], "record_id_list": [...],
                  "has_more": false, "query_context": {...}, "rev": 4424, "timezone": "Asia/Shanghai" } }
    行是**按 fields 顺序排列的数组**，不是按列名索引的对象；select 单元格是数组（["P1"]），
    link 单元格是对象数组（[{"id":"rec..."}]），空单元格是 null，数字列是 number，复选框是 boolean。
    手写 fixture 盖不住这些差别，所以把真实信封脱敏后存成黄金样本，作为归一测试的输入。

    采集命令（只读，不写方向表）：
      lark-cli base +record-list --base-token <token> --table-id tbl2XGd8bO10NBY5 \
          --limit 200 --format json --as user

    token 从哪来：参数 -BaseToken，或环境变量 PATROL_BITABLE_BASE_TOKEN。
    **本文件与样本都不含 token / app secret**；采集只在内存里用，不落盘、不回显。

    ── 脱敏规则（固定、可审；同样输入 ⇒ 同样输出，无随机、无时间戳）──────────────────
    1. 信封：保留 ok / identity / data{data, fields, field_id_list, field_type_list, has_more,
       query_context, record_id_list, rev, timezone}。丢弃 lark-cli 自己的 `_notice`（版本提示，
       与本样本无关）；rev 换成固定虚构值 1000（不发布真实表版本号）。
    2. 行选择：按「特征清单」逐项取表序第一条命中行、去重、最多 -MaxRows 行（默认 8）：
       间隔=0 / 间隔=null / 假数据=true / 优先级=P1 / 父记录非空 / 审批状态非空 /
       动作类型=decision / 执行器非空。清单命中不足 8 行时就少几行，不补造。
       行序 = 原表序，保证「同一张表两次采集得到同一份样本」。
    3. 列级规则（按列名；列名本身是 schema，不是数据，原样保留）：
       项目名            -> 示例项目-01、示例项目-02 …（按行序号，同型短名）
       仓库路径          -> 按原值形状：`（未克隆）https://...` -> `（未克隆）https://example.invalid/example-org/project-NN`；
                            `X:\...` -> `D:\example-repos\project-NN`；`https://...` -> `https://example.invalid/...`；
                            其余相对路径 -> `02_demo\project-NN`
       GitHub            -> `https://example.invalid/example-org/project-NN` 或 `example-org/project-NN`（同型）
       codex_thread_id   -> 同型 UUID（00000000-0000-4000-8000-<12 位十六进制>，由「列名+行号」哈希决定）
       会话ID            -> 同上
       最近执行时间      -> 同型 ISO 时间串（2026-01-0N T09:0M:00.000+08:00 / ...Z，保留原时区写法）
       父记录 (link)     -> [{"id":"rec..."}] -> [{"id":"<虚构 rec id>"}]（保留 link 的对象数组形状）
       其余 text 列       -> 逐行替换为 `[虚构]` + `虚` 填充（保留换行符种类、行数、空行位置；
                            单行上限 64 字符）。覆盖：用户批注/外部成就/目标/下一步/简要描述/
                            相关文档/待审行动/衡量指标/巡检占用；**未知列按 text 处理**（默认拒绝）。
       select 列         -> 原样保留（受控词表：难度/分类/授权边界/审批状态/优先级/协作形态/
                            动作类型/最近结果/贡献类型/当前阶段/执行器），数组形状不变
       checkbox / number -> 原样保留（假数据模式 / 巡检间隔(分钟)）
       null              -> 原样保留（「缺列」在矩阵里就是 null，这个特征必须留住）
    4. 标识符：record_id_list 的每个 id -> `rec` + 12 位小写 base36（由行序号哈希决定）；
       field_id_list 的每个 id -> `fld` + 7 位小写 base36（由列名哈希决定）。长度与形态同真实值。
    5. 采集后自检（不过就不写文件）：样本里不得出现原始 record id / 原始 field id /
       任一被脱敏列的原始值、`github.com`、`gitAll`、`soboy`/`sobey`、邮件地址、明文 http://；
       https:// 只允许 example.invalid；text 列不得有超过 64 字符的单元格。

    产物：tests/fixtures/bitable-record-list.golden.json（UTF-8 无 BOM，2 空格缩进）

    用法：
      $env:PATROL_BITABLE_BASE_TOKEN = '<token>'
      pwsh -NoProfile -File tests/record-bitable-golden.ps1
      pwsh -NoProfile -File tests/record-bitable-golden.ps1 -Out D:\tmp\golden.json
      pwsh -NoProfile -File tests/record-bitable-golden.ps1 -CheckOnly   # 只校验已有样本，不联网

    失败时的行为：没有 token / 没有 lark-cli / 网络或鉴权失败 -> 报错退出 1，**不写样本**，
    也不伪造。他人重采就是把上面那条命令 + 本脚本在自己的凭据下再跑一次。
#>
param(
    # 飞书 base token；不给则读环境变量 PATROL_BITABLE_BASE_TOKEN
    [string]$BaseToken = $env:PATROL_BITABLE_BASE_TOKEN,
    # 方向表 table id（默认与 dsh-patrol docs/policy-v4-triage.md 记的一致）
    [string]$TableId = 'tbl2XGd8bO10NBY5',
    [string]$LarkCli = 'lark-cli',
    [string]$Identity = 'user',
    # 输出路径；默认 <repo>/tests/fixtures/bitable-record-list.golden.json
    [string]$Out = '',
    # 最多保留几行（特征清单命中行，按表序）
    [int]$MaxRows = 8,
    # 只校验已有样本的脱敏与形状，不采集
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path (Join-Path $repoRoot 'tests\fixtures') 'bitable-record-list.golden.json' }

# ---------------------------------------------------------------------------
# 确定性的假值生成（同一个 seed => 同一个假值，采集可复现）
# ---------------------------------------------------------------------------
function Get-FakeToken {
    param([string]$Seed, [int]$Length, [string]$Alphabet = '0123456789abcdefghijklmnopqrstuvwxyz')
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Seed))
    $sb = [System.Text.StringBuilder]::new()
    $i = 0
    while ($sb.Length -lt $Length) {
        $b = $hash[$i % $hash.Length]
        [void]$sb.Append($Alphabet[$b % $Alphabet.Length])
        $i++
    }
    return $sb.ToString()
}

function Get-FakeRecordId {
    param([int]$Ordinal)
    return 'rec' + (Get-FakeToken -Seed ('record-' + $Ordinal) -Length 12)
}

function Get-FakeFieldId {
    param([string]$Column)
    return 'fld' + (Get-FakeToken -Seed ('field-' + $Column) -Length 7)
}

# 多行文本：保留换行符种类 / 行数 / 空行位置，只把每行内容换成等长的虚构串（上限 64 字符）
function Hide-FreeText {
    param([string]$Text)
    $parts = [regex]::Split($Text, "(`r`n|`n|`r)")
    $sb = [System.Text.StringBuilder]::new()
    foreach ($part in $parts) {
        if ($part -eq "`r`n" -or $part -eq "`n" -or $part -eq "`r") { [void]$sb.Append($part); continue }
        if ($part.Length -eq 0) { continue }
        $n = [Math]::Min($part.Length, 64)
        if ($n -le 4) { [void]$sb.Append('虚' * $n) }
        else { [void]$sb.Append('[虚构]' + ('虚' * ($n - 4))) }
    }
    return $sb.ToString()
}

function Hide-RepoPath {
    param([string]$Value, [int]$Ordinal)
    $n = '{0:D2}' -f ($Ordinal + 1)
    if ($Value.StartsWith('（未克隆）')) { return '（未克隆）https://example.invalid/example-org/project-' + $n }
    if ($Value -match '^https?://') { return 'https://example.invalid/example-org/project-' + $n }
    if ($Value -match '^[A-Za-z]:\\') { return 'D:\example-repos\project-' + $n }
    return '02_demo\project-' + $n
}

function Hide-GitHub {
    param([string]$Value, [int]$Ordinal)
    $n = '{0:D2}' -f ($Ordinal + 1)
    if ($Value -match '^https?://') { return 'https://example.invalid/example-org/project-' + $n }
    return 'example-org/project-' + $n
}

function Hide-Id {
    param([string]$Value, [string]$Seed)
    if ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        return '00000000-0000-4000-8000-' + (Get-FakeToken -Seed $Seed -Length 12)
    }
    # 非 UUID 的会话 id（例如 mvs_<32 hex>）：保留前缀字母与总长度，主体换成虚构串
    if ($Value -match '^(?<prefix>[A-Za-z]{2,6}_)?(?<body>[0-9A-Za-z]{8,})$') {
        $prefix = if ($Matches.prefix) { $Matches.prefix } else { '' }
        return $prefix + (Get-FakeToken -Seed $Seed -Length $Matches.body.Length)
    }
    return Hide-FreeText -Text $Value
}

function Hide-Timestamp {
    param([string]$Value, [int]$Ordinal)
    if ($Value -match 'Z$') { return ('2026-01-{0:D2}T09:{1:D2}:00.000Z' -f ((($Ordinal) % 9) + 1), (($Ordinal * 7) % 60)) }
    # 若 JSON 被解析成 [datetime]（未带 -DateKind String 的旧环境），仍给出同型虚构串
    return ('2026-01-{0:D2}T09:{1:D2}:00.000+08:00' -f ((($Ordinal) % 9) + 1), (($Ordinal * 7) % 60))
}

# 父记录是 link 列：数组里的对象可能带 id / text
function Hide-LinkCell {
    param($Cell, [int]$Ordinal)
    $out = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($element in @($Cell)) {
        if ($null -eq $element) { $out.Add($null); $i++; continue }
        $obj = [ordered]@{}
        if ($element -is [System.Collections.IDictionary]) {
            foreach ($k in $element.Keys) { $obj[[string]$k] = $element[$k] }
        }
        elseif ($element -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $element.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        }
        if ($obj.Contains('id')) { $obj['id'] = Get-FakeRecordId -Ordinal (100 + $Ordinal * 10 + $i) }
        if ($obj.Contains('text')) { $obj['text'] = Hide-FreeText -Text ([string]$obj['text']) }
        if ($obj.Count -eq 0) { $out.Add((Hide-FreeText -Text ([string]$element))); $i++; continue }
        $out.Add([pscustomobject]$obj)
        $i++
    }
    return , $out.ToArray()
}

# 受控词表列：值本身是分类，不是项目数据 —— 原样保留（数组形状也保留）
$script:VocabularyColumns = @('难度', '分类', '授权边界', '审批状态', '优先级', '协作形态', '动作类型', '最近结果', '贡献类型', '当前阶段', '执行器')

# 形状规则列：按原值形态换成同型虚构值（不是逐行文本替换），自检时单独按形态断言
$script:ShapeColumns = @('项目名', '仓库路径', 'GitHub', 'codex_thread_id', '会话ID', '最近执行时间', '父记录')

# 返回 @{ Value = <原始形状的脱敏值> }：用 hashtable 当容器，避开 PowerShell 把单元素数组
# / 数组本身展平进管道的问题（否则 ["P1"] 会变成 "P1"，样本就不再是真实形状）。
function Get-SanitizedCell {
    param([string]$Column, [string]$FieldType, $Value, [int]$Ordinal)
    if ($null -eq $Value) { return @{ Value = $null } }
    $seed = '{0}#{1}' -f $Column, $Ordinal
    $out = $null
    switch ($Column) {
        '项目名' { $out = ('示例项目-{0:D2}' -f ($Ordinal + 1)) }
        '仓库路径' { $out = (Hide-RepoPath -Value ([string]$Value) -Ordinal $Ordinal) }
        'GitHub' { $out = (Hide-GitHub -Value ([string]$Value) -Ordinal $Ordinal) }
        'codex_thread_id' { $out = (Hide-Id -Value ([string]$Value) -Seed $seed) }
        '会话ID' { $out = (Hide-Id -Value ([string]$Value) -Seed $seed) }
        '最近执行时间' { $out = (Hide-Timestamp -Value ([string]$Value) -Ordinal $Ordinal) }
        '父记录' { $out = (Hide-LinkCell -Cell $Value -Ordinal $Ordinal) }
        default {
            if ($script:VocabularyColumns -contains $Column) {
                # 词表列：逐个元素原样保留（数组就是数组，含单元素数组）
                if ($Value -is [array]) { $out = @($Value) } else { $out = $Value }
            }
            elseif ($Value -is [array]) {
                $mapped = @(foreach ($el in $Value) {
                        if ($null -eq $el) { $null }
                        elseif ($el -is [string]) { Hide-FreeText -Text $el }
                        else { $el }
                    })
                $out = $mapped
            }
            elseif ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { $out = $Value }
            else { $out = (Hide-FreeText -Text ([string]$Value)) }
        }
    }
    return @{ Value = $out }
}

# ---------------------------------------------------------------------------
# 行选择：特征清单，逐项取表序第一条命中行，去重，保持表序，最多 $MaxRows 行
# ---------------------------------------------------------------------------
function Select-GoldenRows {
    param($Fields, $Matrix)
    $idx = @{}
    for ($j = 0; $j -lt $Fields.Count; $j++) { $idx[[string]$Fields[$j]] = $j }
    $cellOf = {
        param($row, [string]$name)
        if (-not $idx.ContainsKey($name)) { return $null }
        return $row[$idx[$name]]
    }
    $criteria = @(
        @{ Name = 'interval-zero'; Match = { param($r) (& $cellOf $r '巡检间隔(分钟)') -eq 0 } },
        @{ Name = 'interval-null'; Match = { param($r) $null -eq (& $cellOf $r '巡检间隔(分钟)') } },
        @{ Name = 'fake-true'; Match = { param($r) (& $cellOf $r '假数据模式') -eq $true } },
        @{ Name = 'priority-p1'; Match = { param($r) $v = & $cellOf $r '优先级'; if ($v -is [array]) { $v = $v[0] }; [string]$v -eq 'P1' } },
        @{ Name = 'parent-link'; Match = { param($r) $v = & $cellOf $r '父记录'; ($null -ne $v) -and ($v -is [array]) } },
        @{ Name = 'approval-set'; Match = { param($r) $null -ne (& $cellOf $r '审批状态') } },
        @{ Name = 'action-decision'; Match = { param($r) $v = & $cellOf $r '动作类型'; if ($v -is [array]) { $v = $v[0] }; [string]$v -eq 'decision' } },
        @{ Name = 'executor-set'; Match = { param($r) $null -ne (& $cellOf $r '执行器') } }
    )
    $picked = [System.Collections.Generic.List[int]]::new()
    $why = @{}
    foreach ($c in $criteria) {
        if ($picked.Count -ge $MaxRows) { break }
        for ($i = 0; $i -lt $Matrix.Count; $i++) {
            if ($picked.Contains($i)) { continue }
            if (& $c.Match $Matrix[$i]) { $picked.Add($i); $why[$i] = $c.Name; break }
        }
    }
    # 表序输出（不是清单顺序）
    $sorted = @($picked | Sort-Object)
    return [pscustomobject]@{ Indexes = $sorted; Why = $why }
}

# ---------------------------------------------------------------------------
# 自检：样本里不得留下原始标识符 / 原始文本 / 常见泄漏面
# ---------------------------------------------------------------------------
function Get-ForbiddenFragments {
    param($Raw, [string[]]$Fields)
    $frags = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in @($Raw.data.record_id_list)) { if ($id) { [void]$frags.Add([string]$id) } }
    foreach ($id in @($Raw.data.field_id_list)) { if ($id) { [void]$frags.Add([string]$id) } }
    for ($j = 0; $j -lt $Fields.Count; $j++) {
        $column = [string]$Fields[$j]
        if ($script:VocabularyColumns -contains $column) { continue }
        # 形状规则列的产物是完整替换（路径 / URL / UUID / 时间串），不参与「原文片段」比对，
        # 否则 ‘https://’ 这种结构性前缀会假命中；它们由 Assert-SampleSanitized 的形态断言管。
        if ($script:ShapeColumns -contains $column) { continue }
        foreach ($row in @($Raw.data.data)) {
            $v = $row[$j]
            if ($null -eq $v) { continue }
            $text = if ($v -is [array]) { (@($v | ForEach-Object { if ($null -ne $_) { [string]$_ } }) -join "`n") } else { [string]$v }
            if ($text.Length -lt 4) { continue }
            # 每段取若干 8 字符窗口：够短，能抓「样本里还剩半句原文」。
            # 纯数字/标点片段不算（1440 这类数字本来就保留在巡检间隔等列里）。
            $start = 0
            while ($start -lt $text.Length) {
                $len = [Math]::Min(8, $text.Length - $start)
                if ($len -ge 4) {
                    $frag = $text.Substring($start, $len)
                    if ($frag -notmatch '^[0-9\s:.,，。()（）\-—/+]+$' -and $frag -notmatch '^https?://?$') { [void]$frags.Add($frag) }
                }
                if ($start + 8 -ge $text.Length) { break }
                $start += [Math]::Max(1, [int][Math]::Floor(($text.Length - 8) / 4))
            }
        }
    }
    return , @($frags)
}

function Assert-SampleSanitized {
    param($Sample, $Raw, [string[]]$Fields)
    $problems = [System.Collections.Generic.List[string]]::new()
    $json = ConvertTo-Json -InputObject $Sample -Depth 30

    foreach ($frag in (Get-ForbiddenFragments -Raw $Raw -Fields $Fields)) {
        if ($frag.Length -lt 4) { continue }
        if ($json.IndexOf($frag, [System.StringComparison]::Ordinal) -ge 0) {
            $problems.Add(('残留原始片段（长度 {0}，前 2 字：{1}…）' -f $frag.Length, $frag.Substring(0, [Math]::Min(2, $frag.Length))))
            break
        }
    }
    foreach ($literal in @('github.com', 'gitee.com', 'gitAll', 'sobey', 'soboy', 'http://')) {
        if ($json.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $problems.Add("命中禁用子串：$literal") }
    }
    if ($json -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') { $problems.Add('命中邮件地址形态') }
    foreach ($m in [regex]::Matches($json, 'https?://[^"\s\\]+')) {
        if ($m.Value -notmatch '^https://example\.invalid/') { $problems.Add('出现非 example.invalid 的 URL') ; break }
    }
    foreach ($rid in @($Sample.data.record_id_list)) {
        if ([string]$rid -notmatch '^rec[0-9a-z]{12}$') { $problems.Add("record id 形态不符：$rid") }
    }
    foreach ($fid in @($Sample.data.field_id_list)) {
        if ([string]$fid -notmatch '^fld[0-9a-z]{7}$') { $problems.Add("field id 形态不符：$fid") }
    }
    # 形状规则列：产物必须落在允许的虚构形态里（否则就是漏脱敏或换了形状）
    $allowed = @{
        '项目名'       = '^示例项目-\d{2}$'
        '仓库路径'     = '^(（未克隆）)?https://example\.invalid/example-org/project-\d{2}$|^D:\\example-repos\\project-\d{2}$|^02_demo\\project-\d{2}$'
        'GitHub'       = '^(https://example\.invalid/example-org/project-\d{2}|example-org/project-\d{2})$'
        'codex_thread_id' = '^00000000-0000-4000-8000-[0-9a-z]{12}$|^(?:[A-Za-z]{2,6}_)?[0-9a-z]{8,}$'
        '会话ID'       = '^00000000-0000-4000-8000-[0-9a-z]{12}$|^(?:[A-Za-z]{2,6}_)?[0-9a-z]{8,}$'
        '最近执行时间' = '^2026-01-\d{2}T09:\d{2}:00\.000(\+08:00|Z)$'
    }
    $fieldsForShape = @($Sample.data.fields)
    for ($j = 0; $j -lt $fieldsForShape.Count; $j++) {
        $column = [string]$fieldsForShape[$j]
        if (-not $allowed.ContainsKey($column)) { continue }
        foreach ($row in @($Sample.data.data)) {
            $v = $row[$j]
            if ($null -eq $v) { continue }
            if ([string]$v -notmatch $allowed[$column]) {
                $problems.Add(('列 {0} 的脱敏值不在允许形态内' -f $column))
                break
            }
        }
    }

    # text 列不得有超长单元格（脱敏后单行上限 64）
    $fields = @($Sample.data.fields)
    for ($j = 0; $j -lt $fields.Count; $j++) {
        foreach ($row in @($Sample.data.data)) {
            $v = $row[$j]
            if ($v -is [string]) {
                foreach ($line in [regex]::Split($v, "(`r`n|`n|`r)")) {
                    if ($line.Length -gt 64) { $problems.Add(('列 {0} 有超过 64 字符的单元格（{1} 字符）' -f $fields[$j], $line.Length)); break }
                }
            }
        }
    }
    return , @($problems)
}

# ---------------------------------------------------------------------------
# 读样本 / 生成样本
# ---------------------------------------------------------------------------
if ($CheckOnly) {
    if (-not (Test-Path -LiteralPath $Out)) { throw "CheckOnly: 样本不存在：$Out" }
    $sample = [System.IO.File]::ReadAllText($Out, $script:Utf8NoBom) | ConvertFrom-Json -AsHashtable
    # 无原始表可比时只做「形态 + 禁用子串」自检：把 raw 置成同形状的空壳
    $shim = @{ data = @{ record_id_list = @(); field_id_list = @(); data = @(); fields = @($sample.data.fields) } }
    $problems = Assert-SampleSanitized -Sample $sample -Raw $shim -Fields @($sample.data.fields)
    if ($problems.Count -gt 0) {
        Write-Host 'FAIL golden sample check'
        foreach ($p in $problems) { Write-Host "     $p" }
        exit 1
    }
    Write-Host ('PASS golden sample check: {0} 行 / {1} 列 / {2} 字节' -f @($sample.data.data).Count, @($sample.data.fields).Count, (Get-Item -LiteralPath $Out).Length)
    exit 0
}

if ([string]::IsNullOrWhiteSpace($BaseToken)) {
    throw @'
缺 base token：-BaseToken 或环境变量 PATROL_BITABLE_BASE_TOKEN 都没有。
本脚本不内置任何凭据，也不伪造样本。取到 token 后重跑：
  $env:PATROL_BITABLE_BASE_TOKEN = '<token>'
  pwsh -NoProfile -File tests/record-bitable-golden.ps1
'@
}
if (-not (Get-Command -Name $LarkCli -ErrorAction SilentlyContinue)) {
    throw "找不到 lark-cli（$LarkCli）：装好或 -LarkCli 指路。采集失败不写样本。"
}

$cliArgs = @('base', '+record-list', '--base-token', $BaseToken, '--table-id', $TableId, '--limit', '200', '--format', 'json', '--as', $Identity)
Write-Host ("collect: lark-cli base +record-list --table-id {0} --limit 200 --format json --as {1}" -f $TableId, $Identity)
$rawText = (& $LarkCli @cliArgs 2>&1 | Out-String)
$exit = $LASTEXITCODE
if ($exit -ne 0) {
    # 只报退出码与首行类别，不回显可能含凭据的命令行
    throw ("lark-cli 取数失败（exit={0}）。首行：{1}" -f $exit, (($rawText -split "`r?`n")[0]))
}
$raw = $rawText | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String
if ($raw.ok -ne $true) { throw ('lark-cli 返回 ok!=true：' + (($rawText -split "`r?`n")[0])) }

$fields = @($raw.data.fields)
$matrix = @($raw.data.data)
$recordIds = @($raw.data.record_id_list)
$fieldTypes = @($raw.data.field_type_list)
Write-Host ("raw: {0} 行 x {1} 列（rev={2}，has_more={3}）" -f $matrix.Count, $fields.Count, $raw.data.rev, $raw.data.has_more)

$selection = Select-GoldenRows -Fields $fields -Matrix $matrix
Write-Host ('selected rows: {0}' -f (@($selection.Indexes) -join ','))
foreach ($i in $selection.Indexes) { Write-Host ('     row {0} <- {1}' -f $i, $selection.Why[$i]) }

$typeOf = @{}
for ($j = 0; $j -lt $fields.Count; $j++) { $typeOf[[string]$fields[$j]] = if ($j -lt $fieldTypes.Count) { [string]$fieldTypes[$j] } else { '' } }

$newRows = [System.Collections.Generic.List[object]]::new()
$newIds = [System.Collections.Generic.List[string]]::new()
for ($o = 0; $o -lt @($selection.Indexes).Count; $o++) {
    $src = $matrix[$selection.Indexes[$o]]
    $cells = [System.Collections.Generic.List[object]]::new()
    for ($j = 0; $j -lt $fields.Count; $j++) {
        $column = [string]$fields[$j]
        $value = if ($j -lt $src.Count) { $src[$j] } else { $null }
        $cells.Add((Get-SanitizedCell -Column $column -FieldType $typeOf[$column] -Value $value -Ordinal $o).Value)
    }
    $newRows.Add([object[]]$cells.ToArray())
    $newIds.Add((Get-FakeRecordId -Ordinal $o))
}

$sample = [ordered]@{
    ok       = $true
    identity = [string]$raw.identity
    data     = [ordered]@{
        data           = [object[]]$newRows.ToArray()
        field_id_list  = [object[]]@($fields | ForEach-Object { Get-FakeFieldId -Column ([string]$_) })
        field_type_list = [object[]]$fieldTypes
        fields         = [object[]]$fields
        has_more       = $false
        query_context  = [ordered]@{ field_scope = 'all_fields'; record_scope = 'all_records' }
        record_id_list = [object[]]$newIds.ToArray()
        rev            = 1000
        timezone       = [string]$raw.data.timezone
    }
}

$problems = Assert-SampleSanitized -Sample $sample -Raw $raw -Fields $fields
if ($problems.Count -gt 0) {
    Write-Host 'FAIL 脱敏自检：不写样本'
    foreach ($p in $problems) { Write-Host "     $p" }
    exit 1
}

$target = [System.IO.Path]::GetFullPath($Out)
$dir = Split-Path -Parent $target
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$json = ConvertTo-Json -InputObject $sample -Depth 30
[System.IO.File]::WriteAllText($target, $json + "`n", $script:Utf8NoBom)
Write-Host ('wrote {0} ({1} bytes, {2} rows, UTF-8 no BOM)' -f $target, (Get-Item -LiteralPath $target).Length, $newRows.Count)
Write-Host 'RESULT: PASS'
exit 0
