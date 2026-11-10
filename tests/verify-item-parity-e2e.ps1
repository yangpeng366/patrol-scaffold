#requires -Version 7
<#
    tests/verify-item-parity-e2e.ps1 — 两仓对同一份行数据的**端到端**解析对拍（只读 / 离线 / 零新依赖）

    和 tests/verify-item-contract-parity.ps1 的分工：
      - contract-parity 比「两边 schema 的约束面」——静态契约同不同源；
      - 本脚本比「同一行喂进两套真实解析代码后，逐字段结果相不相等」——动态行为同不同源。
    两者缺一不可：schema 一样而解析不一样（比如一边把 interval=0 悄悄改成 60），静态闸门永远看不见。

    左侧（本仓，生产代码）：dot-source scripts/BitAbleAdapter.ps1，调 Convert-BitableRowToItem。
    右侧（兄弟仓，只读）：Node + `--experimental-strip-types` 直接 import dsh-patrol 的
      `src/source/bitable.ts`（COLUMNS 列映射 + BitableSource.listItems）与 `src/source/provider.ts`
      （normalizeItem），只把 lark-cli 子进程换成注入的 exec 返回 fixture 信封
      —— 不手抄 normalizeItem（抄一份只能证明抄得像），不联网，不碰真表。
    比较：两侧输出都摊成「字段 -> 带类型标签的 token」，取键并集逐字段比；类型也必须相等
      （threadId 的 '' 与 null 是两种形状，不能因为"看起来都空"就放过）。

    三态（与本仓其它闸门同一口径：SKIP 永远不是 PASS）：
      PASS  exit 0  两侧都在、逐字段相等
      SKIP  exit 0  兄弟仓不存在 / 没有 node / Node 不支持类型擦除（环境不具备，输出写明缺什么）
      FAIL  exit 1  任一字段不等 / 任一侧少字段 / 右侧解析报错

    自证（默认开启，-NoSelfTest 关闭）：把右侧样本故意改坏（数值 +1、null 变空串），
    断言比较器真的会红——否则「全绿」可能只是比较器什么都没比。

    用法：
      pwsh -NoProfile -File tests/verify-item-parity-e2e.ps1
      pwsh -NoProfile -File tests/verify-item-parity-e2e.ps1 -DshRepo D:\gitAll\dsh-patrol
      pwsh -NoProfile -File tests/verify-item-parity-e2e.ps1 -Verbose   # 额外打印 node 命令行
#>
param(
    # 兄弟仓 dsh-patrol 的克隆根目录；不给则按仓库相对位置找 ..\dsh-patrol
    [string]$DshRepo = '',
    # 本仓 Bitable 适配器路径，默认 <repo>/scripts/BitAbleAdapter.ps1
    [string]$Adapter = '',
    # 对拍用的 Node 可执行文件；不给则从 PATH 取 node
    [string]$NodeExe = '',
    [switch]$NoSelfTest
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Adapter) { $Adapter = Join-Path (Join-Path $repoRoot 'scripts') 'BitAbleAdapter.ps1' }
# 与 verify-item-contract-parity.ps1 同一口径：路径是推出来的 -> 缺文件 = 环境不具备（SKIP）；
# 显式 -DshRepo 指路却指空 -> 手滑（FAIL），不让闸门因为拼错参数静默变绿。
$explicitDshRepo = -not [string]::IsNullOrWhiteSpace($DshRepo)
if (-not $DshRepo) { $DshRepo = Join-Path (Split-Path -Parent $repoRoot) 'dsh-patrol' }

# ---------------------------------------------------------------------------
# fixture：同一份行数据同时喂两边（左 = PSCustomObject，右 = 同一对象的 JSON）
#   - 正常行 / 缺 巡检间隔(分钟) / 间隔为 0 / 优先级 P3
#   - 假数据模式 true / false 各一（外加一个字符串 "true"，证明两边都只认真布尔）
#   - 空白与大小写、空串 threadId、非整数间隔各一条，专打平时最容易"看起来一样"的地方
# 列名一律用 Bitable 真表的列名（与 dsh 的 COLUMNS 同一张表）。
# ---------------------------------------------------------------------------
$Fixtures = @(
    [ordered]@{
        name = 'rec-normal'
        note = '正常行：全列齐、P1、90 分钟、有 threadId、假数据 false'
        row  = [ordered]@{
            record_id         = 'rec-normal'
            '项目名'          = 'scaffold 契约对拍'
            '仓库路径'        = 'D:\gitAll\patrol-scaffold'
            '简要描述'        = '两端解析结果逐字段相等'
            '下一步'          = '跑 e2e 对拍'
            '优先级'          = 'P1'
            '巡检间隔(分钟)'  = 90
            'codex_thread_id' = 'thread-abc'
            '假数据模式'      = $false
            '当前阶段'        = '进行中'
            '外部成就'        = '对拍脚本已落地'
            '授权边界'        = '需审批'
            '协作形态'        = 'dense'
            '审批状态'        = '待审'
            '待审行动'        = '合并到 main'
            '分类'            = '工作项目'
            '最近执行时间'    = '2026-11-10T08:00:00.000Z'
        }
    },
    [ordered]@{
        name = 'rec-no-interval'
        note = '缺 巡检间隔(分钟) 列：两边都应是 0（不是 60）'
        row  = [ordered]@{
            record_id         = 'rec-no-interval'
            '项目名'          = '缺间隔'
            '优先级'          = 'P2'
            'codex_thread_id' = 'thread-def'
            '假数据模式'      = $false
        }
    },
    [ordered]@{
        name = 'rec-zero-interval'
        note = '巡检间隔 = 0：契约层必须原样保留 0（调度层才决定怎么回退）'
        row  = [ordered]@{
            record_id        = 'rec-zero-interval'
            '项目名'          = '零间隔'
            '优先级'          = 'P0'
            '巡检间隔(分钟)'  = 0
            '假数据模式'      = $false
        }
    },
    [ordered]@{
        name = 'rec-priority-p3'
        note = '优先级 P3：不在 enum 内，两边都降 P2'
        row  = [ordered]@{
            record_id        = 'rec-priority-p3'
            '项目名'          = '非法优先级'
            '优先级'          = 'P3'
            '巡检间隔(分钟)'  = 30
            '假数据模式'      = $false
        }
    },
    [ordered]@{
        name = 'rec-fake-true'
        note = '假数据模式 true + 缺 threadId：fake=true、threadId=null'
        row  = [ordered]@{
            record_id        = 'rec-fake-true'
            '项目名'          = '假数据行'
            '优先级'          = 'P1'
            '巡检间隔(分钟)'  = 15
            '假数据模式'      = $true
        }
    },
    [ordered]@{
        name = 'rec-fake-string'
        note = '假数据模式 = 字符串 "true"：两边都只认真布尔，应同为 false；threadId 空串 -> null'
        row  = [ordered]@{
            record_id         = 'rec-fake-string'
            '项目名'          = '文本假数据'
            '优先级'          = 'P2'
            '巡检间隔(分钟)'  = 120
            '假数据模式'      = 'true'
            'codex_thread_id' = ''
        }
    },
    [ordered]@{
        name = 'rec-whitespace-frac'
        note = '优先级带空白/小写 + 非整数间隔 45.7 + 空串 threadId：P0 / 45 / null'
        row  = [ordered]@{
            record_id         = 'rec-whitespace-frac'
            '项目名'          = '  空白与小数  '
            '优先级'          = ' p0 '
            '巡检间隔(分钟)'  = 45.7
            'codex_thread_id' = ''
            '假数据模式'      = $false
            '授权边界'        = ''
        }
    }
)

# ---------------------------------------------------------------------------
# 值 <-> token：两侧统一成 "类型标签:值" 短串再比。
#   为什么不用 JSON 原生类型：PowerShell 的 ConvertFrom-Json 会把 ISO 时间串自动转成
#   [DateTime]，lastRun 到 PS 侧就变成区域格式，对拍会假红。带前缀的 token 不会。
#   z = null（没有冒号），s: 字符串，n: 数字，b: 布尔。
# ---------------------------------------------------------------------------
$script:NumericTypeNames = @('Byte', 'SByte', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64', 'Single', 'Double', 'Decimal')
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function ConvertTo-Token {
    param($Value)
    if ($null -eq $Value) { return 'z' }
    if ($Value -is [bool]) { if ($Value) { return 'b:true' } else { return 'b:false' } }
    if ($script:NumericTypeNames -contains $Value.GetType().Name) {
        return 'n:' + ([double]$Value).ToString('R', $script:Invariant)
    }
    return 's:' + [string]$Value
}

function Get-TokenKind {
    param([string]$Token)
    if ([string]::IsNullOrEmpty($Token)) { return 'absent' }
    if ($Token -eq 'z') { return 'null' }
    return $Token.Substring(0, 1)
}

function Format-Token {
    param([string]$Token)
    if ([string]::IsNullOrEmpty($Token)) { return '<absent>' }
    if ($Token -eq 'z') { return 'null' }
    if ($Token.StartsWith('s:')) { return "'" + $Token.Substring(2) + "'" }
    return $Token.Substring(2)
}

function Test-TokenEqual {
    param([string]$Left, [string]$Right)
    if ([string]::IsNullOrEmpty($Left) -or [string]::IsNullOrEmpty($Right)) { return $false }
    $lk = Get-TokenKind -Token $Left
    $rk = Get-TokenKind -Token $Right
    if ($lk -ne $rk) { return $false }
    if ($lk -eq 'null') { return $true }
    if ($lk -eq 'number') {
        $ln = 0.0; $rn = 0.0
        $okL = [double]::TryParse($Left.Substring(2), [System.Globalization.NumberStyles]::Float, $script:Invariant, [ref]$ln)
        $okR = [double]::TryParse($Right.Substring(2), [System.Globalization.NumberStyles]::Float, $script:Invariant, [ref]$rn)
        if (-not ($okL -and $okR)) { return $false }
        return ($ln -eq $rn)
    }
    return ([string]::Equals($Left, $Right, [System.StringComparison]::Ordinal))
}

# 把一个 item 摊成 字段 -> token；键按名字排序，输出稳定可比
function ConvertTo-TokenItem {
    param($Item)
    $map = [ordered]@{}
    if ($null -eq $Item) { return $map }
    if ($Item -is [System.Collections.IDictionary]) {
        foreach ($k in @($Item.Keys | Sort-Object)) { $map[[string]$k] = ConvertTo-Token -Value $Item[$k] }
        return $map
    }
    foreach ($p in @($Item.PSObject.Properties | Sort-Object -Property Name)) { $map[[string]$p.Name] = ConvertTo-Token -Value $p.Value }
    return $map
}

# 逐字段比：返回 { Rows = 每个字段的两边值, Diffs = 不一致清单 }
function Compare-TokenItem {
    param($LeftMap, $RightMap)
    $fields = @(@($LeftMap.Keys) + @($RightMap.Keys)) | Sort-Object -Unique
    $rows = New-Object System.Collections.Generic.List[object]
    $diffs = New-Object System.Collections.Generic.List[string]
    foreach ($f in $fields) {
        $l = if ($LeftMap.Contains($f)) { [string]$LeftMap[$f] } else { $null }
        $r = if ($RightMap.Contains($f)) { [string]$RightMap[$f] } else { $null }
        $ok = Test-TokenEqual -Left $l -Right $r
        $rows.Add([pscustomobject]@{ Field = $f; Ok = $ok; Left = (Format-Token -Token $l); Right = (Format-Token -Token $r) })
        if (-not $ok) {
            $detail = if ($null -eq $l) { '左缺该字段' }
            elseif ($null -eq $r) { '右缺该字段' }
            elseif ((Get-TokenKind -Token $l) -ne (Get-TokenKind -Token $r)) { "类型不同（left=$(Get-TokenKind -Token $l) right=$(Get-TokenKind -Token $r)）" }
            else { '值不同' }
            $diffs.Add(('{0}: left={1} right={2}（{3}）' -f $f, (Format-Token -Token $l), (Format-Token -Token $r), $detail))
        }
    }
    return [pscustomobject]@{ Rows = $rows; Diffs = $diffs }
}

# ---------------------------------------------------------------------------
# 两侧取值
# ---------------------------------------------------------------------------
function New-RowsDocument {
    # 把 fixture 写成一份「Bitable 表」：fields 是列并集（不含 record_id，它是行 ID 不是列）
    $fields = New-Object System.Collections.Generic.List[string]
    foreach ($f in $Fixtures) {
        foreach ($k in $f.row.Keys) {
            if ($k -eq 'record_id') { continue }
            if (-not $fields.Contains([string]$k)) { $fields.Add([string]$k) }
        }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Fixtures) {
        $cells = [ordered]@{}
        foreach ($k in $f.row.Keys) {
            if ($k -eq 'record_id') { continue }
            $cells[[string]$k] = $f.row[$k]
        }
        $rows.Add([ordered]@{ recordId = [string]$f.row.record_id; cells = $cells })
    }
    # 注意：这里是 List + ToArray()，不要用 @($list) 去包「元素是嵌套 ordered dict」的 List
    #（PowerShell 7.5 在这种形状上会抛 "Argument types do not match"）。
    return [ordered]@{ fields = $fields.ToArray(); rows = $rows.ToArray() }
}

function New-RowObject {
    param($OrderedRow)
    $o = [ordered]@{}
    foreach ($k in $OrderedRow.Keys) { $o[[string]$k] = $OrderedRow[$k] }
    return [pscustomobject]$o
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
Write-Host 'item parity e2e: patrol-scaffold(PS 生产实现) <-> dsh-patrol(TS 原码) 逐字段对拍'
Write-Host ('left  = {0} :: Convert-BitableRowToItem' -f $Adapter)
Write-Host ('right = {0} :: BitableSource.listItems(COLUMNS) -> normalizeItem（只读 import，不手抄）' -f (Join-Path $DshRepo 'src\source\bitable.ts'))
Write-Host ('fixtures = {0} 条（同一份行数据同时喂两侧）' -f $Fixtures.Count)

$rightModules = @(
    (Join-Path $DshRepo 'src\source\bitable.ts'),
    (Join-Path $DshRepo 'src\source\provider.ts')
)
$missing = @($rightModules | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missing.Count -gt 0) {
    foreach ($m in $missing) { Write-Host ('     missing: {0}' -f $m) }
    if ($explicitDshRepo) {
        Write-Host 'FAIL item-parity-e2e: -DshRepo 显式指路但读不到兄弟仓源码（拼错路径 / 稀疏 checkout 没带 src）'
        Write-Host 'RESULT: FAIL'
        exit 1
    }
    Write-Host 'SKIP item-parity-e2e'
    Write-Host '     兄弟仓 dsh-patrol 不在本机（或未含 src/source）：本环境无从判定，不计 FAIL 也不算 PASS'
    Write-Host 'RESULT: SKIP'
    exit 0
}
if (-not (Test-Path -LiteralPath $Adapter -PathType Leaf)) {
    Write-Host ('FAIL item-parity-e2e: 本仓适配器不存在 {0}' -f $Adapter)
    Write-Host 'RESULT: FAIL'
    exit 1
}

if (-not $NodeExe) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $NodeExe = $cmd.Source }
}
if (-not $NodeExe -or -not (Test-Path -LiteralPath $NodeExe -PathType Leaf)) {
    Write-Host 'SKIP item-parity-e2e'
    Write-Host '     node not found on PATH (need Node >= 22.6 for --experimental-strip-types)'
    Write-Host '     右侧要跑兄弟仓的 TypeScript 原码，没有 node 就无法判定；不冒充 PASS'
    Write-Host 'RESULT: SKIP'
    exit 0
}

# 探测类型擦除能力：老 node 不认这个 flag（bad option），那就是环境不具备 -> SKIP
$nodeFlags = @('--experimental-strip-types', '--no-warnings')
$probeOut = & $NodeExe @nodeFlags -e 'process.exit(0)' 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host 'SKIP item-parity-e2e'
    Write-Host ('     node {0} 不认 --experimental-strip-types，无法直接跑 .ts 原码（需要 Node >= 22.6）' -f (& $NodeExe --version))
    foreach ($line in @($probeOut)) { Write-Host ('     {0}' -f $line) }
    Write-Host 'RESULT: SKIP'
    exit 0
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-item-parity-e2e-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$rowsPath = Join-Path $sandbox 'rows.json'

$diffs = New-Object System.Collections.Generic.List[string]
$leftMaps = New-Object System.Collections.Generic.List[object]
$rightMaps = New-Object System.Collections.Generic.List[object]
$compared = New-Object System.Collections.Generic.List[object]
$fieldCount = 0

try {
    # ---- 1) 左侧：本仓生产代码 ----
    $rowsDoc = New-RowsDocument
    [System.IO.File]::WriteAllText($rowsPath, (ConvertTo-Json -InputObject $rowsDoc -Depth 8), $script:Utf8NoBom)
    . $Adapter
    foreach ($f in $Fixtures) {
        $leftMaps.Add((ConvertTo-TokenItem -Item (Convert-BitableRowToItem -Row (New-RowObject -OrderedRow $f.row))))
    }

    # ---- 2) 右侧：兄弟仓 TypeScript 原码（node 直跑，不落构建产物）----
    $harness = Join-Path $PSScriptRoot 'normalize-item-dsh.mjs'
    $nodeArgList = @($nodeFlags) + @($harness, '--repo', $DshRepo, '--rows', $rowsPath)
    Write-Verbose ('node {0}' -f ($nodeArgList -join ' '))
    $nodeOut = & $NodeExe @nodeArgList 2>&1
    $nodeExit = $LASTEXITCODE
    if ($nodeExit -ne 0) {
        $diffs.Add(("右侧 dsh 解析失败（node exit={0}）`n        {1}" -f $nodeExit, (@($nodeOut) -join "`n        ")))
    }
    else {
        $text = (@($nodeOut) -join "`n")
        $parsed = ConvertFrom-Json -InputObject $text
        Write-Host ('right modules loaded: bitable={0}' -f $parsed.dsh.bitable)
        Write-Host ('                      provider={0}' -f $parsed.dsh.provider)
        Write-Host ('node = {0} (strip-types)；lark-cli 子进程被 exec 注入替换为 fixture 信封' -f $parsed.dsh.node)
        $rightItems = @($parsed.items)
        if ($rightItems.Count -ne $Fixtures.Count) {
            $diffs.Add(("右侧返回 {0} 条，期望 {1} 条" -f $rightItems.Count, $Fixtures.Count))
        }
        foreach ($ri in $rightItems) {
            $m = [ordered]@{}
            foreach ($p in @($ri.PSObject.Properties | Sort-Object -Property Name)) { $m[[string]$p.Name] = [string]$p.Value }
            $rightMaps.Add($m)
        }
    }

    # ---- 3) 逐字段对拍 ----
    $pairs = [Math]::Min($leftMaps.Count, $rightMaps.Count)
    for ($i = 0; $i -lt $pairs; $i++) {
        $cmp = Compare-TokenItem -LeftMap $leftMaps[$i] -RightMap $rightMaps[$i]
        Write-Host ''
        Write-Host ('[{0}/{1}] {2}  {3}' -f ($i + 1), $Fixtures.Count, $Fixtures[$i].name, $Fixtures[$i].note)
        foreach ($row in $cmp.Rows) {
            $mark = if ($row.Ok) { 'OK  ' } else { 'DIFF' }
            Write-Host ('        {0} {1} left={2} | right={3}' -f $mark, $row.Field.PadRight(18), $row.Left.PadRight(34), $row.Right)
        }
        foreach ($d in $cmp.Diffs) { $diffs.Add(('{0}  {1}' -f $Fixtures[$i].name, $d)) }
        $compared.Add($cmp)
        if ($cmp.Rows.Count -gt $fieldCount) { $fieldCount = $cmp.Rows.Count }
    }
    if ($leftMaps.Count -ne $Fixtures.Count) { $diffs.Add(("左侧返回 {0} 条，期望 {1} 条" -f $leftMaps.Count, $Fixtures.Count)) }

    # ---- 4) 自证：把右侧样本改坏，比较器必须红 ----
    if (-not $NoSelfTest -and $rightMaps.Count -gt 0) {
        $selfFail = 0
        $probe = [ordered]@{}
        foreach ($k in $rightMaps[0].Keys) { $probe[$k] = $rightMaps[0][$k] }
        $numField = @($probe.Keys | Where-Object { (Get-TokenKind -Token $probe[$_]) -eq 'n' })[0]
        $numValue = [double]::Parse(([string]$probe[$numField]).Substring(2), [System.Globalization.NumberStyles]::Float, $script:Invariant)
        $probe[$numField] = 'n:' + ($numValue + 1).ToString('R', $script:Invariant)
        if (@((Compare-TokenItem -LeftMap $leftMaps[0] -RightMap $probe).Diffs).Count -eq 0) {
            $selfFail++; Write-Host ('FAIL selftest: 数值字段 {0} 改 +1 后比较器没报 DIFF' -f $numField)
        }
        else { Write-Host ('PASS selftest: 数值字段 {0} 改 +1 后比较器报 DIFF' -f $numField) }

        $probe2 = [ordered]@{}
        foreach ($k in $rightMaps[0].Keys) { $probe2[$k] = $rightMaps[0][$k] }
        $nullField = @($probe2.Keys | Where-Object { (Get-TokenKind -Token $probe2[$_]) -eq 'null' })
        if ($nullField.Count -gt 0) {
            $probe2[$nullField[0]] = 's:'
            $label = '把 {0} 的 null 换成空串' -f $nullField[0]
        }
        else {
            $probe2[$numField] = 's:' + ([string]$probe2[$numField]).Substring(2)
            $label = '把 {0} 的 number 换成同值字符串' -f $numField
        }
        if (@((Compare-TokenItem -LeftMap $leftMaps[0] -RightMap $probe2).Diffs).Count -eq 0) {
            $selfFail++; Write-Host ('FAIL selftest: {0} 后比较器没报类型不同' -f $label)
        }
        else { Write-Host ('PASS selftest: {0} 后比较器报类型不同' -f $label) }

        if ($selfFail -gt 0) { $diffs.Add(('selftest {0} 条断言未通过（比较器会说谎，本次结论不可信）' -f $selfFail)) }
    }
}
finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('summary items={0} fields-per-item={1} diffs={2}' -f $compared.Count, $fieldCount, $diffs.Count)
if ($diffs.Count -gt 0) {
    Write-Host 'FAIL item-parity-e2e: 两仓对同一行的解析结果不一致'
    foreach ($d in $diffs) { Write-Host ('     {0}' -f $d) }
    Write-Host 'RESULT: FAIL'
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
