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
       片段比对只在「样本单元格的值」上做（不做在整份 JSON 上）：整份 JSON 里有列名会误报，
       而 JSON 把 `\` / 换行转义后，含 Windows 路径或分段叙述的原文永远匹配不到。
       另有正向白名单 Assert-FakeCellShape：逐格断言只能出现虚构形态，穷举、与原始表无关，
       所以 -CheckOnly 也是真的在查内容，而不只是查形态。

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
    # 单行虚构文本的上限；原值更短时保持等长，用来保留长度相关断言
    # 默认 64 与上面「text 列不得有超过 64 字符的单元格」的约定一致（改默认会让已入库样本
    # 与新采样本的行宽口径不同，等于把 64 字符断言变成一条空断言）。
    [int]$MaxTextLength = 64,
    # 离线读取一份原始 record-list JSON（测试用）；给了就不联网、不读 token
    [string]$RawJson = '',
    # 只校验已有样本的脱敏与形状，不采集
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:TextLimit = [Math]::Max(16, $MaxTextLength)
$script:RecordIdMap = @{}
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
        $n = [Math]::Min($part.Length, $script:TextLimit)
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
    param($Value, [int]$Ordinal)
    # Preserve the type and the offset spelling. A numeric epoch stays numeric; a Z / +08:00
    # string keeps that suffix. The day/minute are synthetic and deterministic.
    $day = (($Ordinal % 9) + 1)
    $minute = (($Ordinal * 7) % 60)
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        if ([string]$Value -match '^\d{10}$') { return [long](1767225600 + ($Ordinal * 60)) }
        return [long](1767225600000 + ($Ordinal * 60000))
    }
    $s = [string]$Value
    if ($s.Length -eq 0) { return '' }
    if ($s -match '^\d{10}$') { return [long](1767225600 + ($Ordinal * 60)) }
    if ($s -match '^\d{13}$') { return [long](1767225600000 + ($Ordinal * 60000)) }
    if ($s -match '^\d{4}-\d{2}-\d{2}$') { return ('2026-01-{0:D2}' -f $day) }
    if ($s -match '(?<offset>[+-]\d{2}:\d{2})$') {
        $offset = [string]$Matches.offset
        return ('2026-01-{0:D2}T09:{1:D2}:00.000{2}' -f $day, $minute, $offset)
    }
    if ($s -match 'Z$') { return ('2026-01-{0:D2}T09:{1:D2}:00.000Z' -f $day, $minute) }
    return ('2026-01-{0:D2}T09:{1:D2}:00.000' -f $day, $minute)
}

function Get-FakeStructuredId {
    param([string]$Value, [string]$Seed)
    if ($Value -match '^rec[0-9A-Za-z]+$') {
        if ($script:RecordIdMap.ContainsKey($Value)) { return $script:RecordIdMap[$Value] }
        return 'rec' + (Get-FakeToken -Seed $Seed -Length 12)
    }
    if ($Value -match '^ou_[0-9a-fA-F]+$') { return 'ou_' + (Get-FakeToken -Seed $Seed -Length 32 -Alphabet '0123456789abcdef') }
    if ($Value -match '^fld[0-9A-Za-z]+$') { return 'fld' + (Get-FakeToken -Seed $Seed -Length 7)
    }
    if ($Value -match '^(?<prefix>[A-Za-z]{2,6}_)(?<body>[0-9A-Za-z_-]+)$') {
        $prefix = [string]$Matches.prefix
        $length = $Matches.body.Length
        return $prefix + (Get-FakeToken -Seed $Seed -Length $length)
    }
    # 不带下划线的 token（file_token 的 boxcn…、table_id 的 tbl…、user_id 的 8 位十六进制）
    # 原来统一变成 `id_` + 16 字符，长度与字符集都变了，黄金样本就不再是「同形态」输入。
    # 保留长度 + 字符集，前缀丢失无所谓（适配器只用 rec/fld/ou_ 前缀做语义区分）。
    if ($Value -match '^[0-9a-fA-F]{8,32}$') {
        return Get-FakeToken -Seed $Seed -Length $Value.Length -Alphabet '0123456789abcdef'
    }
    if ($Value -match '^[0-9A-Za-z]{8,64}$') {
        return Get-FakeToken -Seed $Seed -Length $Value.Length
    }
    return 'id_' + (Get-FakeToken -Seed $Seed -Length 16)
}

# 结构化单元格（公式 / 查找引用 / 附件元数据）里的数字同样是原始内容：金额、计数、时间戳。
# 保留原类型与位数，只把数值换成由 seed 决定的虚构值。0 与布尔是结构性取值，保持原样。
function Get-FakeDigits {
    param([string]$Seed, [int]$Count)
    if ($Count -lt 1) { return '0' }
    $digits = Get-FakeToken -Seed $Seed -Length $Count -Alphabet '0123456789'
    # 首位不能是 0，否则位数会缩一档
    if ($digits[0] -eq '0') { $digits = '1' + $digits.Substring(1) }
    return $digits
}

function Hide-StructuredNumber {
    param($Value, [string]$Seed)
    if ($Value -is [bool]) { return $Value }
    $abs = [Math]::Abs([double]$Value)
    # 0 与纯小数没有可用位数可换，留着（不携带项目信息）
    if ($abs -lt 1) { return $Value }
    $digits = [int][Math]::Floor([Math]::Log10($abs)) + 1
    if ($digits -gt 18) { $digits = 18 }
    $fake = [int64]::Parse((Get-FakeDigits -Seed $Seed -Count $digits))
    if ([double]$Value -lt 0) { $fake = -$fake }
    if ($Value -is [int]) { return [int][Math]::Min($fake, [int]::MaxValue) }
    if ($Value -is [long]) { return [int64]$fake }
    if ($Value -is [decimal]) { return [decimal]$fake }
    return [double]$fake
}

# Any object/array that is not covered by a column rule goes through this recursive cleaner.
# Nothing is passed through: an unknown object key is cleaned by its value, not copied.
function Hide-StructuredValue {
    param($Value, [string]$Seed, [string]$Key = '')
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Key -match '(?i)(url|link|href|avatar)') { return 'https://example.invalid/structured' }
        if ($Value -match '^https?://') { return 'https://example.invalid/structured' }
        if ($Value -match '^[^@\s]+@[^@\s]+$') { return 'user@example.invalid' }
        return Hide-FreeText -Text $Value
    }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        # 原来是原样返回：公式 / 查找引用里的金额与计数就是真实数据，且 Get-StringLeaves
        # 不收集数字，连自检都看不见它。改成同类型同位数的虚构值。
        return Hide-StructuredNumber -Value $Value -Seed $Seed
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
    if ($Value -is [byte[]]) {
        # byte[] 也是 IEnumerable，不拦住就会被枚举成数字数组：形状变了（不是泄漏，
        # 但样本入库存的是字节，换成长度相同的假字节更贴真实形状）
        $bytes = [byte[]]::new($Value.Length)
        for ($b = 0; $b -lt $Value.Length; $b++) {
            $hex = Get-FakeToken -Seed ($Seed + '/byte' + $b) -Length 2 -Alphabet '0123456789abcdef'
            $bytes[$b] = [Convert]::ToByte($hex, 16)
        }
        return ,$bytes
    }
        $dict = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $dict[$p.Name] = $p.Value }
        return Hide-StructuredValue -Value $dict -Seed $Seed -Key $Key
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $obj = [ordered]@{}
        foreach ($k in $Value.Keys) {
            $name = [string]$k
            if ($name -match '(?i)^(id|record_id|open_id|user_id|union_id|app_id|table_id|field_id|file_token|token)$') {
                $obj[$name] = Get-FakeStructuredId -Value ([string]$Value[$k]) -Seed ($Seed + '/' + $name)
            }
            else {
                $obj[$name] = Hide-StructuredValue -Value $Value[$k] -Seed ($Seed + '/' + $name) -Key $name
            }
        }
        return [pscustomobject]$obj
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        $i = 0
        foreach ($element in $Value) {
            $list.Add((Hide-StructuredValue -Value $element -Seed ($Seed + '/' + $i) -Key $Key))
            $i++
        }
        return ,$list.ToArray()
    }
    return Hide-FreeText -Text ([string]$Value)
}

function Hide-LinkCell {
    param($Cell, [int]$Ordinal)
    $sanitized = Hide-StructuredValue -Value $Cell -Seed ('link#' + $Ordinal)
    return ,$sanitized
}

# 受控词表列：值本身是分类，不是项目数据 —— 原样保留（数组形状也保留）
$script:VocabularyColumns = @('难度', '分类', '授权边界', '审批状态', '优先级', '协作形态', '动作类型', '最近结果', '贡献类型', '当前阶段', '执行器')

# 形状规则列：按原值形态换成同型虚构值（不是逐行文本替换），自检时单独按形态断言
$script:ShapeColumns = @('项目名', '仓库路径', 'GitHub', 'codex_thread_id', '会话ID', '最近执行时间', '父记录')

# 强受控词表：不在表内的选项直接让采集失败，避免把新加的自由文本选项带进样本。
$script:VocabularyValues = @{
    '难度' = @('入门', '简单', '中等', '困难', '专家')
    '分类' = @('工作项目', '兴趣研究', '开源项目', '个人项目')
    '授权边界' = @('只读', '自主')
    '审批状态' = @('已通过', '待审', '阻塞', '已拒绝')
    '优先级' = @('P0', 'P1', 'P2')
    '协作形态' = @('sparse', 'approve', 'dense', 'none')
    '动作类型' = @('repo-code', 'repo-test', 'repo-doc', 'field-ops', 'release', 'secret', 'config', 'decision', 'unclear')
    '最近结果' = @('成功', '失败', '阻塞', '跳过', '进行中', '待开始')
    '贡献类型' = @('功能增强', '文档完善', '研究探索', 'bug修复', '性能优化', '重构', '测试')
    '当前阶段' = @('开发', '维护', '规划', '验证', '暂停', '归档', '进行中', '已完成', '已实现', '待开始', '完成(dry-run)', 'HUMAN_REVIEW pending')
    '执行器' = @('mcode', 'codex', 'manual')
}
$script:VocabularyPattern = '^[\p{L}\p{N}()（）._\- ]{1,32}$'

# 正向白名单：一个字符串叶子只要出现在样本里，就必须是 sanitizer 能产出的虚构形态之一。
# 这是黑名单（Get-ForbiddenFragments）够不到的兜底：4~5 字符的短值原本既不做整值比对
# 也不做窗口比对；分段叙述 / 含反斜杠的原文在序列化后的 JSON 里根本匹配不到。
# 按列类型分档，text 列只容许「[虚构]+虚」，免得通用的 `前缀_主体` 形态把真 open_id 也放过。
$script:FakeTextLine = '^(?:\[虚构\]虚*|虚+)$'
$script:FakeTimeValue = '^(?:2026-01-\d{2}T09:\d{2}:00\.000(?:\+08:00|Z)?|\d{10,13})$'
$script:FakeUrlValue = '^https://example\.invalid/[A-Za-z0-9/_.\-]*$'
$script:FakeStructuredLeaf = '(?i)^(?:https://example\.invalid/[A-Za-z0-9/_.\-]*|user@example\.invalid|rec[0-9a-z]{12}|fld[0-9a-z]{7}|ou_[0-9a-f]{32}|id_[0-9a-z]{16}|[A-Za-z]{2,6}_[0-9A-Za-z_\-]+|2026-01-\d{2}T09:\d{2}:00\.000(?:\+08:00|Z)?|\d{10,13}|\[虚构\]虚*|虚+)$'

# 采样与行选择会按名索骥；缺列时不要继续生成一份错位样本。
$script:RequiredColumns = @($script:VocabularyColumns + $script:ShapeColumns + @('巡检间隔(分钟)', '假数据模式')) | Sort-Object -Unique

function Assert-VocabularyValue {
    param([string]$Column, $Value)
    $text = [string]$Value
    if ($script:VocabularyValues.ContainsKey($Column)) {
        if ($script:VocabularyValues[$Column] -notcontains $text) {
            # 报错只回显前 2 字：词表列的值也可能是真实项目名，进 CI 日志就是泄漏
            throw ('列 {0} 的值不在受控词表内（长度 {1}，前 2 字：{2}…）；请先把该选项加入 VocabularyValues 再重采' -f $Column, $text.Length, $text.Substring(0, [Math]::Min(2, $text.Length)))
        }
        return $text
    }
    # 词表列没有登记受控选项 = 无法判断这个值是不是分类。旧实现退回宽松正则，
    # 任何 1~32 字符的自由文本都能原样进样本，而片段自检又把整列跳过，等于双重静默。
    # 这里 fail-closed，与「未知 select 列」同一处置：先登记词表，再重采。
    throw ('列 {0} 没有登记受控词表（VocabularyValues）；无法判断该值是分类还是项目数据，拒绝写入样本' -f $Column)
    return $text
}

function Get-NormalizedFieldType {
    param($Value)
    $s = ([string]$Value).Trim()
    if ($s -eq '1') { return 'text' }
    if ($s -eq '2') { return 'number' }
    if ($s -eq '3') { return 'select' }
    if ($s -eq '4') { return 'multi_select' }
    if ($s -eq '5') { return 'datetime' }
    if ($s -eq '7') { return 'checkbox' }
    if ($s -eq '11') { return 'user' }
    if ($s -eq '13') { return 'phone' }
    if ($s -eq '15') { return 'url' }
    if ($s -eq '17') { return 'attachment' }
    if ($s -eq '18') { return 'link' }
    if ($s -eq '19') { return 'lookup' }
    if ($s -eq '20') { return 'formula' }
    # 21 = 双向关联（旧名 duoshu）；它和 18 单向关联一样返回 [{id,text}] 数组，按 link 处理
    if ($s -eq '21') { return 'link' }
    if ($s -eq '22') { return 'location' }
    if ($s -eq '23') { return 'group_chat' }
    if ($s -eq '1001') { return 'created_time' }
    if ($s -eq '1002') { return 'modified_time' }
    if ($s -eq '1003') { return 'created_user' }
    if ($s -eq '1004') { return 'modified_user' }
    if ($s -eq '1005') { return 'auto_number' }
    return $s.ToLowerInvariant()
}

# 返回 @{ Value = <原始形状的脱敏值> }：用 hashtable 当容器，避开 PowerShell 把单元素数组
# / 数组本身展平进管道的问题（否则 ["P1"] 会变成 "P1"，样本就不再是真实形状）。
function Get-SanitizedCell {
    param([string]$Column, [string]$FieldType, $Value, [int]$Ordinal)
    if ($null -eq $Value) { return @{ Value = $null } }
    $seed = '{0}#{1}' -f $Column, $Ordinal
    $type = Get-NormalizedFieldType -Value $FieldType
    $out = $null
    switch ($Column) {
        '项目名' { $out = ('示例项目-{0:D2}' -f ($Ordinal + 1)) }
        '仓库路径' { $out = (Hide-RepoPath -Value ([string]$Value) -Ordinal $Ordinal) }
        'GitHub' { $out = (Hide-GitHub -Value ([string]$Value) -Ordinal $Ordinal) }
        'codex_thread_id' { $out = (Hide-Id -Value ([string]$Value) -Seed $seed) }
        '会话ID' { $out = (Hide-Id -Value ([string]$Value) -Seed $seed) }
        '最近执行时间' { $out = (Hide-Timestamp -Value $Value -Ordinal $Ordinal) }
        '父记录' { $out = (Hide-LinkCell -Cell $Value -Ordinal $Ordinal) }
        default {
            if ($script:VocabularyColumns -contains $Column) {
                if ($Value -is [array]) {
                    $mapped = @(foreach ($el in $Value) {
                            if ($null -eq $el) { $null }
                            elseif ($el -is [string]) { Assert-VocabularyValue -Column $Column -Value $el }
                            else { throw ('列 {0} 的 select 单元里有非字符串元素，拒绝写入样本' -f $Column) }
                        })
                    $out = $mapped
                }
                else { $out = Assert-VocabularyValue -Column $Column -Value $Value }
            }
            elseif ($type -eq 'select' -or $type -eq 'multi_select') {
                throw ('未知 select 列「{0}」：先加进 VocabularyColumns 与 VocabularyValues，再重采' -f $Column)
            }
            elseif ($type -eq 'checkbox') {
                if ($Value -is [bool]) { $out = $Value } else { throw ('列 {0} 是 checkbox，但值不是布尔' -f $Column) }
            }
            elseif ($type -eq 'number' -or $type -eq 'auto_number') {
                if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { $out = $Value }
                else { throw ('列 {0} 是数字列，但值不是数字' -f $Column) }
            }
            elseif ($type -eq 'datetime' -or $type -eq 'created_time' -or $type -eq 'modified_time') {
                if ($Value -is [array]) { $out = @(foreach ($el in $Value) { Hide-Timestamp -Value $el -Ordinal $Ordinal }) }
                else { $out = Hide-Timestamp -Value $Value -Ordinal $Ordinal }
            }
            elseif ($type -eq 'link') {
                $out = Hide-LinkCell -Cell $Value -Ordinal $Ordinal
            }
            elseif ($type -eq 'text' -and $Value -is [string]) {
                $out = Hide-FreeText -Text $Value
            }
            else {
                # user / attachment / lookup / formula / unknown: never pass the element through.
                $out = Hide-StructuredValue -Value $Value -Seed $seed
            }
        }
    }
    return @{ Value = $out }
}

function Assert-TableShape {
    param($Raw)
    $fields = @($Raw.data.fields)
    $fieldIds = @($Raw.data.field_id_list)
    $fieldTypes = @($Raw.data.field_type_list)
    $matrix = @($Raw.data.data)
    $recordIds = @($Raw.data.record_id_list)
    if ($fields.Count -ne $fieldIds.Count) { throw ('fields={0} 与 field_id_list={1} 数量不一致' -f $fields.Count, $fieldIds.Count) }
    if ($fields.Count -ne $fieldTypes.Count) { throw ('fields={0} 与 field_type_list={1} 数量不一致' -f $fields.Count, $fieldTypes.Count) }
    if ($matrix.Count -ne $recordIds.Count) { throw ('data={0} 行与 record_id_list={1} 数量不一致' -f $matrix.Count, $recordIds.Count) }
    # 重名列会让 Select-GoldenRows 的按名取列与 $typeOf 默默被后一列覆盖（采集出「看起来对」
    # 但列错位的样本），飞书前端虽不允许重名，导入/改名仍可能造出来，所以在这里 fail-closed。
    $dupes = @($fields | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { [string]$_.Name })
    if ($dupes.Count -gt 0) { throw ('方向表有重名列：{0}；按名取列会错位，拒绝采样' -f ($dupes -join ', ')) }
    for ($i = 0; $i -lt $matrix.Count; $i++) {
        if (@($matrix[$i]).Count -ne $fields.Count) { throw ('第 {0} 行有 {1} 个单元，fields 有 {2} 个；列错位时拒绝采样' -f $i, @($matrix[$i]).Count, $fields.Count) }
    }
    $missing = @($script:RequiredColumns | Where-Object { $fields -notcontains [string]$_ })
    if ($missing.Count -gt 0) { throw ('方向表缺少必需列：{0}' -f ($missing -join ', ')) }
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
        # PowerShell 的 -eq 对数组是筛选语义：[0,5] -eq 0 得 @(0) 且为真，
        # 旧写法会把「间隔=[0,5]」的行走成「间隔=0」。这里只认标量数值 0。
        @{ Name = 'interval-zero'; Match = { param($r)
                $v = & $cellOf $r '巡检间隔(分钟)'
                if ($null -eq $v -or $v -is [array]) { return $false }
                if ($v -isnot [int] -and $v -isnot [long] -and $v -isnot [double] -and $v -isnot [decimal]) { return $false }
                return ([double]$v -eq 0)
            } },
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
function Get-StringLeaves {
    param($Value)
    $out = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) { return ,$out.ToArray() }
    if ($Value -is [string]) { $out.Add($Value); return ,$out.ToArray() }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) {
            foreach ($s in (Get-StringLeaves -Value $p.Value)) { $out.Add($s) }
        }
        return ,$out.ToArray()
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) {
            foreach ($s in (Get-StringLeaves -Value $Value[$k])) { $out.Add($s) }
        }
        return ,$out.ToArray()
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($element in $Value) {
            foreach ($s in (Get-StringLeaves -Value $element)) { $out.Add($s) }
        }
        return ,$out.ToArray()
    }
    return ,$out.ToArray()
}

# 样本里「单元格里的字符串」——片段比对只在这些值上做，不碰字段名，也不经 JSON 序列化。
# 两个原因：字段名也进 haystack 会把「某一格的值恰好等于某列名」误判成泄漏；
# 而 JSON 把 `\` 逃逸成 `\\`、换行逃逸成 `\n` 后，含 Windows 路径或分段叙述的原文
# 永远匹配不到（那是本工具最需要查住的形态）。这里拿的是反序列化之后的值本身。
function Get-SampleValueLeaves {
    param($Sample)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($row in @($Sample.data.data)) {
        foreach ($cell in @($row)) {
            foreach ($s in (Get-StringLeaves -Value $cell)) { $out.Add($s) }
        }
    }
    foreach ($id in @($Sample.data.record_id_list)) { if ($null -ne $id) { $out.Add([string]$id) } }
    return , $out.ToArray()
}

# 正向契约：每一格只能出现 sanitizer 能产出的虚构形态。
# 它不需要原始表在场，所以 -CheckOnly 也从「只验形状」变成「真的验内容」；
# 同时覆盖了黑名单的两种盲区：4~5 字符短值（低于整值比对门槛）与分段叙述（转义后匹配不到）。
function Assert-FakeCellShape {
    param($Sample)
    $problems = [System.Collections.Generic.List[string]]::new()
    $fields = @($Sample.data.fields)
    $types = @()
    if ($null -ne $Sample.data.field_type_list) { $types = @($Sample.data.field_type_list) }
    for ($j = 0; $j -lt $fields.Count; $j++) {
        $column = [string]$fields[$j]
        # 词表列走 allowlist 断言；形状列走各自的形态断言；数字/复选框没有字符串叶子
        if ($script:VocabularyColumns -contains $column) {
            # 词表列：反向校验「样本里的值仍在当前词表内」。采集时已经 fail-closed 过，
            # 但 -CheckOnly 没有原始表可比：一份陈旧样本里的旧选项照样能过关，这里补上。
            $allowedOptions = @()
            if ($script:VocabularyValues.ContainsKey($column)) { $allowedOptions = @($script:VocabularyValues[$column]) }
            foreach ($row in @($Sample.data.data)) {
                foreach ($text in (Get-StringLeaves -Value $row[$j])) {
                    if ($text.Length -eq 0) { continue }
                    if ($allowedOptions -notcontains $text) {
                        $problems.Add(('列 {0} 的值不在当前受控词表内（长度 {1}，前 2 字：{2}…）；样本可能已过期' -f $column, $text.Length, $text.Substring(0, [Math]::Min(2, $text.Length))))
                    }
                }
            }
            if ($problems.Count -ge 8) { return , @($problems) }
            continue
        }
        if ($script:ShapeColumns -contains $column) { continue }
        $type = 'text'
        if ($j -lt $types.Count) { $type = Get-NormalizedFieldType -Value $types[$j] }
        if ($type -in @('number', 'auto_number', 'checkbox')) { continue }
        # 按列类型选白名单：text/phone 只容「[虚构]+虚」（即使值长得像 ou_... 也不行），
        # 时间列只容虚构时间串，url 列只容 example.invalid，结构化列才用宽口径（假 id/邮箱/自由文本）。
        $pattern = switch ($type) {
            { $_ -in @('text', 'phone') } { $script:FakeTextLine }
            { $_ -in @('datetime', 'created_time', 'modified_time') } { $script:FakeTimeValue }
            'url' { $script:FakeUrlValue }
            default { $script:FakeStructuredLeaf }
        }
        foreach ($row in @($Sample.data.data)) {
            foreach ($text in (Get-StringLeaves -Value $row[$j])) {
                foreach ($line in [regex]::Split($text, "(`r`n|`n|`r)")) {
                    if ($line.Length -eq 0) { continue }
                    # [regex]::Split 带捕获组时会把分隔符本身也留在结果里（`r`n / `n / `r），
                    # 那不是文本内容，得先跳过；否则每一段都会白白报一条。
                    if ($line -match '^(\r\n|\n|\r)$') { continue }
                    if ($line -notmatch $pattern) {
                        # 只回显前 2 字并压掉控制字符：报错信息不能反过来把真实值泄到 CI 日志里
                        $preview = ($line -replace '[\r\n\t]', ' ')
                        $problems.Add(('列 {0} 的单元格不像虚构值（长度 {1}，前 2 字：{2}…）；可能漏了一类形状' -f $column, $line.Length, $preview.Substring(0, [Math]::Min(2, $preview.Length))))
                        break
                    }
                }
                if ($problems.Count -ge 8) { return , @($problems) }
            }
        }
    }
    return , @($problems)
}

function Get-ForbiddenFragments {
    param($Raw, [string[]]$Fields)
    $frags = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in @($Raw.data.record_id_list)) { if ($id) { [void]$frags.Add([string]$id) } }
    foreach ($id in @($Raw.data.field_id_list)) { if ($id) { [void]$frags.Add([string]$id) } }
    for ($j = 0; $j -lt $Fields.Count; $j++) {
        $column = [string]$Fields[$j]
        # Vocabulary values are checked against an allowlist above; they are the one class of
        # strings that intentionally survive. Every other raw string is checked, including the
        # values of user / attachment / lookup / formula objects.
        if ($script:VocabularyColumns -contains $column) { continue }
        foreach ($row in @($Raw.data.data)) {
            foreach ($text in (Get-StringLeaves -Value $row[$j])) {
                if ($text.Length -lt 4) { continue }
                # Keep a whole short value (a secret can be six characters), but only take
                # sliding windows for long values. Four-character windows collide with fake
                # tokens such as file_ / user@ and make the check noisy instead of strict.
                if ($text.Length -ge 6 -and $text -notmatch '^[0-9\s:.,，。()（）\-—/+]+$') { [void]$frags.Add($text) }
                if ($text.Length -lt 8) { continue }
                # Windows are only meaningful for prose. Pure tokens (emails, URLs, file
                # handles, ids) are short and share prefixes by design; windowing them
                # matches the fake namespace (user@example.invalid, file_) and turns a
                # strict check into a noisy one. Whole-value comparison already catches
                # a leaked token, so skip the windows for anything without prose.
                if ($text -notmatch '\s' -and $text -notmatch '[\u4e00-\u9fff]') { continue }
                # 原来的步长 (len-8)/4 让任何长文本都只取到 5 个窗口，中间大段永远取不到，
                # 和注释里的「滑窗」不是一回事。改成等距、最多 9 个窗口（含末尾一窗）。
                # 真正的穷举兜底是 Assert-FakeCellShape 的整格白名单；这里是粗网，
                # 避免在「全表行 × 全列」上生成百万级片段把采集拖成分钟级。
                $step = [Math]::Max(1, [int][Math]::Ceiling(($text.Length - 8) / 8.0))
                $start = 0
                while ($start -le $text.Length - 4) {
                    $len = [Math]::Min(8, $text.Length - $start)
                    $frag = $text.Substring($start, $len)
                    if ($frag -notmatch '^[0-9\s:.,，。()（）\-—/+]+$' -and $frag -notmatch '^https?://?$') { [void]$frags.Add($frag) }
                    $start += $step
                }
            }
        }
    }
    return , @($frags)
}

function Assert-SampleSanitized {
    param($Sample, $Raw, [string[]]$Fields)
    $problems = [System.Collections.Generic.List[string]]::new()
    $json = ConvertTo-Json -InputObject $Sample -Depth 30

    # 片段只在样本的「值」上找，不在整份 JSON 上找（理由见 Get-SampleValueLeaves）：
    # 整份 JSON 既会因字段名误报，也会因 `\` / 换行被转义而漏报。
    $haystack = (Get-SampleValueLeaves -Sample $Sample) -join "`u{0}"
    foreach ($frag in (Get-ForbiddenFragments -Raw $Raw -Fields $Fields)) {
        if ($frag.Length -lt 4) { continue }
        if ($haystack.IndexOf($frag, [System.StringComparison]::Ordinal) -ge 0) {
            $problems.Add(('残留原始片段（长度 {0}，前 2 字：{1}…）' -f $frag.Length, $frag.Substring(0, [Math]::Min(2, $frag.Length))))
            if ($problems.Count -ge 8) { break }
        }
    }
    foreach ($literal in @('github.com', 'gitee.com', 'gitAll', 'sobey', 'soboy', 'http://')) {
        if ($json.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $problems.Add("命中禁用子串：$literal") }
    }
    foreach ($m in [regex]::Matches($json, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')) {
        if ($m.Value -notmatch '@example\.invalid$') { $problems.Add('命中非虚构邮件地址形态'); break }
    }
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
        '最近执行时间' = '^2026-01-\d{2}T09:\d{2}:00\.000(\+08:00|Z)$|^\d{10,13}$'
    }
    $fieldsForShape = @($Sample.data.fields)
    for ($j = 0; $j -lt $fieldsForShape.Count; $j++) {
        $column = [string]$fieldsForShape[$j]
        if (-not $allowed.ContainsKey($column)) { continue }
        foreach ($row in @($Sample.data.data)) {
            $v = $row[$j]
            if ($null -eq $v) { continue }
            if ([string]$v -notmatch $allowed[$column]) {
                $problems.Add(('列 {0} 的脱敏值「{1}」不在允许形态内' -f $column, [string]$v))
                break
            }
        }
    }

    # Every string leaf, including strings inside user/attachment/lookup objects, must respect
    # the same line limit. This is the check that catches an object passed through untouched.
    $fields = @($Sample.data.fields)
    for ($j = 0; $j -lt $fields.Count; $j++) {
        foreach ($row in @($Sample.data.data)) {
            foreach ($text in (Get-StringLeaves -Value $row[$j])) {
                foreach ($line in [regex]::Split($text, "(`r`n|`n|`r)")) {
                    if ($line.Length -gt $script:TextLimit) {
                        $problems.Add(('列 {0} 有超过上限 {1} 的字符串（{2} 字符）' -f $fields[$j], $script:TextLimit, $line.Length))
                        break
                    }
                }
            }
        }
    }

    # 样本自身的形状不变式：行数 / 列宽与信封一致（-CheckOnly 也查，防止手改样本后列错位）
    $sampleFields = @($Sample.data.fields)
    $sampleRows = @($Sample.data.data)
    $sampleIds = @($Sample.data.record_id_list)
    if ($sampleRows.Count -ne $sampleIds.Count) {
        $problems.Add(('样本 data={0} 行与 record_id_list={1} 数量不一致' -f $sampleRows.Count, $sampleIds.Count))
    }
    for ($i = 0; $i -lt $sampleRows.Count; $i++) {
        if (@($sampleRows[$i]).Count -ne $sampleFields.Count) {
            $problems.Add(('样本第 {0} 行有 {1} 个单元，fields 有 {2} 个' -f $i, @($sampleRows[$i]).Count, $sampleFields.Count))
            break
        }
    }

    # 正向契约：逐格断言只能出现虚构形态（穷举；与原始表在不在场无关）
    foreach ($p in (Assert-FakeCellShape -Sample $Sample)) { $problems.Add('白名单：' + $p) }

    return , @($problems)
}

# ---------------------------------------------------------------------------
# 读样本 / 生成样本
# ---------------------------------------------------------------------------
if ($CheckOnly) {
    if (-not (Test-Path -LiteralPath $Out)) { throw "CheckOnly: 样本不存在：$Out" }
    $sample = [System.IO.File]::ReadAllText($Out, $script:Utf8NoBom) | ConvertFrom-Json -AsHashtable -DateKind String
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

if ($RawJson) {
    if (-not (Test-Path -LiteralPath $RawJson)) { throw "RawJson 不存在：$RawJson" }
    $rawText = [System.IO.File]::ReadAllText($RawJson, $script:Utf8NoBom)
    Write-Host ("offline input: {0}" -f $RawJson)
}
else {
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
}

$raw = $rawText | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String
if ($raw.ok -ne $true) { throw ('record-list 返回 ok!=true：' + (($rawText -split "`r?`n")[0])) }
Assert-TableShape -Raw $raw
if ($raw.data.has_more -eq $true -or [string]$raw.data.has_more -eq 'true') {
    throw 'record-list 返回 has_more=true：当前只取 200 行，样本会被截断；先分页取全表再采。'
}

$fields = @($raw.data.fields)
$matrix = @($raw.data.data)
$recordIds = @($raw.data.record_id_list)
$fieldTypes = @($raw.data.field_type_list)
Write-Host ("raw: {0} 行 x {1} 列（rev={2}，has_more={3}）" -f $matrix.Count, $fields.Count, $raw.data.rev, $raw.data.has_more)

$selection = Select-GoldenRows -Fields $fields -Matrix $matrix
if (@($selection.Indexes).Count -eq 0) { throw '特征清单没有命中任何行；空样本不写。' }
Write-Host ('selected rows: {0}' -f (@($selection.Indexes) -join ','))
foreach ($i in $selection.Indexes) { Write-Host ('     row {0} <- {1}' -f $i, $selection.Why[$i]) }

$typeOf = @{}
for ($j = 0; $j -lt $fields.Count; $j++) { $typeOf[[string]$fields[$j]] = Get-NormalizedFieldType -Value $fieldTypes[$j] }

# Link ids that point at a selected row reuse that row's fake id, so the sample is self-consistent.
$script:RecordIdMap.Clear()
for ($o = 0; $o -lt @($selection.Indexes).Count; $o++) {
    $sourceIndex = $selection.Indexes[$o]
    $script:RecordIdMap[[string]$recordIds[$sourceIndex]] = Get-FakeRecordId -Ordinal $o
}

$newRows = [System.Collections.Generic.List[object]]::new()
$newIds = [System.Collections.Generic.List[string]]::new()
for ($o = 0; $o -lt @($selection.Indexes).Count; $o++) {
    $src = $matrix[$selection.Indexes[$o]]
    $cells = [System.Collections.Generic.List[object]]::new()
    for ($j = 0; $j -lt $fields.Count; $j++) {
        $column = [string]$fields[$j]
        # 从 if 语句取值会把单元素数组解包（语句输出进管线会被枚举），
        # 于是 user / 附件 / link 的数组形状就没了。这里用赋值语句，形状保留。
        $value = $null
        if ($j -lt $src.Count) { $value = $src[$j] }
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
