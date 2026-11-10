#requires -Version 7
<#
    tests/verify-item-contract-parity.ps1 — 两仓 item 契约是否真的同源（只读 / 离线 / 零新依赖）

    背景：patrol-scaffold 与 dsh-patrol 各存一份 schemas/item.schema.json，此前只在两边
    文档里写了「同一份契约，改动需同步」，没有任何机器校验。两边一旦漂移，装配层仍能跑，
    但 dsh-patrol 的 normalizeItem / 契约测试与 scaffold 的 adapter 契约测试会各按各的尺子裁，
    漂移只能等真实轮次产出对不上时才暴露。本脚本把「同源」变成会红的能力。

    比较口径（结构化解析后比较，不做字符串/字节比较）：
      - 键集合：任一层的对象键集合必须一致（多一个键 = 契约多一条约束，必须点名）
      - 约束面：type / required / enum / pattern / additionalProperties / minimum /
        maximum / minLength / maxLength / format / items / $schema 等全部按叶子逐条比对
      - required / enum / type 按集合比较（这三处顺序无语义，重排不算漂移）
      - description / title / examples / $comment 是注释面，允许不同；
        差异只打印为 NOTE，不计 FAIL（见下方「为什么不卡注释面」）

    为什么不卡注释面：
      两仓的 description 本来就该各说各话（scaffold 是契约原产地，dsh-patrol 要标注来源路径）。
      把注释也卡成逐字节相同，等于让任何一次措辞润色都变红，闸门会因为噪音被关掉，
      真正该红的约束漂移反而没人看。约束面已经覆盖「一份产出能否通过另一份的校验」。

    三态语义（与本仓其它闸门一致：SKIP 永远不是 FAIL）：
      PASS  exit 0  两侧 schema 都在，且约束面逐键相同
      SKIP  exit 0  -OtherSchema 未给，且默认路径 ..\dsh-patrol\schemas\item.schema.json 不存在
                    （典型场景：CI 只 checkout 了本仓；或本机没 clone 兄弟仓）
                    —— 只表示「本环境无法判定」，绝不冒充 PASS，输出里会写明找的是哪个绝对路径
      FAIL  exit 1  约束面有差异 / 本仓 schema 缺失 / 显式 -OtherSchema 指向的路径不存在
                    （显式指路却指空，是手滑，不是「环境里没有」，所以判红）

    自证（默认开启，-NoSelfTest 关闭）：在 %TEMP% 造 6 个样本断言闸门自己不会说谎——
    好样本必须绿；只改一个 enum 的坏样本必须红并点名 /properties/priority/enum；
    少一个键、翻 additionalProperties、删 required 成员、改注释各一个样本。
    临时目录 finally 删除，仓库零污染。

    用法：
      pwsh -NoProfile -File tests/verify-item-contract-parity.ps1
      pwsh -NoProfile -File tests/verify-item-contract-parity.ps1 -OtherSchema D:\gitAll\dsh-patrol\schemas\item.schema.json
      pwsh -NoProfile -File tests/verify-item-contract-parity.ps1 -NoSelfTest
#>
param(
    # 另一份 item.schema.json 的路径；不给则按仓库相对位置找 ..\dsh-patrol\schemas\item.schema.json
    [string]$OtherSchema = '',
    # 本仓 schema 路径，默认 <repo>/schemas/item.schema.json
    [string]$Schema = '',
    [switch]$NoSelfTest
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# 注释面：允许两仓各说各话，不参与判定
$script:AnnotationKeys = @('description', 'title', 'examples', '$comment')
# 顺序无语义的键：按集合比较
$script:SetKeys = @('required', 'enum', 'type')

$repoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# 结构化比较
# ---------------------------------------------------------------------------
function Test-JsonObject {
    param($Value)
    return ($null -ne $Value) -and ($Value.GetType().Name -eq 'PSCustomObject')
}

function Get-LeafJson {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 32)
}

<#
    把一份 schema 摊平成「路径 -> 约束值」的叶子表。
    路径用 JSON Pointer 风格（/properties/priority/enum），差异可以逐条点名。
    注释键整棵子树跳过；SetKeys 的标量数组先排序再拼，消除顺序噪音。
#>
function Get-ConstraintLeaves {
    param($Node, [string]$Path, [string]$KeyName, [hashtable]$Leaves, [hashtable]$Annotations)

    if (Test-JsonObject $Node) {
        foreach ($prop in $Node.PSObject.Properties) {
            $childPath = if ($Path) { "$Path/$($prop.Name)" } else { "/$($prop.Name)" }
            # 注释面只认「标量键」：properties 下也可能有一个叫 description / title 的属性 schema，
            # 那是契约的一部分（它的 type 必须比对），不能当注释跳过。
            if (($script:AnnotationKeys -contains $prop.Name) -and -not (Test-JsonObject $prop.Value)) {
                $Annotations[$childPath] = Get-LeafJson $prop.Value
                continue
            }
            Get-ConstraintLeaves -Node $prop.Value -Path $childPath -KeyName $prop.Name -Leaves $Leaves -Annotations $Annotations
        }
        return
    }

    if ($Node -is [System.Array]) {
        if ($script:SetKeys -contains $KeyName) {
            $parts = @($Node | ForEach-Object { Get-LeafJson $_ } | Sort-Object)
            $Leaves[$Path] = '[' + ($parts -join ',') + ']'
            return
        }
        for ($i = 0; $i -lt $Node.Count; $i++) {
            Get-ConstraintLeaves -Node $Node[$i] -Path "$Path/$i" -KeyName $KeyName -Leaves $Leaves -Annotations $Annotations
        }
        return
    }

    $Leaves[$Path] = Get-LeafJson $Node
}

function Get-SchemaShape {
    param([string]$Path)
    $json = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
    try {
        $doc = ConvertFrom-Json -InputObject $json
    }
    catch {
        throw ("schema is not valid JSON: {0} :: {1}" -f $Path, $_.Exception.Message)
    }
    $leaves = @{}
    $annotations = @{}
    Get-ConstraintLeaves -Node $doc -Path '' -KeyName '' -Leaves $leaves -Annotations $annotations
    return [pscustomobject]@{ Leaves = $leaves; Annotations = $annotations }
}

function Compare-ConstraintLeaves {
    param([hashtable]$Left, [hashtable]$Right, [System.Collections.Generic.List[string]]$Diffs)

    foreach ($key in (@($Left.Keys) | Sort-Object)) {
        if (-not $Right.ContainsKey($key)) {
            $Diffs.Add(("ONLY-LEFT   {0}`n            left  = {1}`n            right = <key absent>" -f $key, $Left[$key]))
            continue
        }
        if ($Left[$key] -ne $Right[$key]) {
            $Diffs.Add(("DIFF        {0}`n            left  = {1}`n            right = {2}" -f $key, $Left[$key], $Right[$key]))
        }
    }
    foreach ($key in (@($Right.Keys) | Sort-Object)) {
        if (-not $Left.ContainsKey($key)) {
            $Diffs.Add(("ONLY-RIGHT  {0}`n            left  = <key absent>`n            right = {1}" -f $key, $Right[$key]))
        }
    }
}

function Get-AnnotationNotes {
    param([hashtable]$Left, [hashtable]$Right)
    $notes = New-Object System.Collections.Generic.List[string]
    $keys = @(@($Left.Keys) + @($Right.Keys)) | Sort-Object -Unique
    foreach ($key in $keys) {
        $l = if ($Left.ContainsKey($key)) { $Left[$key] } else { '<key absent>' }
        $r = if ($Right.ContainsKey($key)) { $Right[$key] } else { '<key absent>' }
        if ($l -eq $r) { continue }
        $lt = if ($l.Length -gt 48) { $l.Substring(0, 48) + '…' } else { $l }
        $rt = if ($r.Length -gt 48) { $r.Substring(0, 48) + '…' } else { $r }
        $notes.Add(('{0}: left={1} | right={2}' -f $key, $lt, $rt))
    }
    # 前面加逗号：单元素时 PowerShell 会把 List 摊平成一个字符串，后面的 .ToArray() 就炸了
    return , $notes.ToArray()
}

<#
    闸门本体：返回 status = PASS | SKIP | FAIL。
    SkipWhenRightMissing 为真表示「右侧路径是按仓库相对位置推出来的」，
    既然没给路，缺文件就是环境不具备（SKIP）；显式给路还缺文件就是手滑（FAIL）。
#>
function Invoke-ParityGate {
    param(
        [string]$LeftPath,
        [string]$RightPath,
        [bool]$SkipWhenRightMissing = $false
    )

    if (-not (Test-Path -LiteralPath $LeftPath -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'FAIL'; Diffs = @(("left schema missing: {0}" -f $LeftPath)); Notes = @(); Keys = 0 }
    }
    if (-not (Test-Path -LiteralPath $RightPath -PathType Leaf)) {
        $status = if ($SkipWhenRightMissing) { 'SKIP' } else { 'FAIL' }
        $detail = if ($SkipWhenRightMissing) { "right schema not present in this checkout: $RightPath" } else { "right schema not found (explicit path): $RightPath" }
        return [pscustomobject]@{ Status = $status; Diffs = @($detail); Notes = @(); Keys = 0 }
    }

    try {
        $left = Get-SchemaShape -Path $LeftPath
        $right = Get-SchemaShape -Path $RightPath
    }
    catch {
        return [pscustomobject]@{ Status = 'FAIL'; Diffs = @($_.Exception.Message); Notes = @(); Keys = 0 }
    }

    $diffs = New-Object System.Collections.Generic.List[string]
    Compare-ConstraintLeaves -Left $left.Leaves -Right $right.Leaves -Diffs $diffs
    $notes = @(Get-AnnotationNotes -Left $left.Annotations -Right $right.Annotations)
    $status = if ($diffs.Count -gt 0) { 'FAIL' } else { 'PASS' }
    return [pscustomobject]@{ Status = $status; Diffs = @($diffs); Notes = @($notes); Keys = $left.Leaves.Count }
}

# ---------------------------------------------------------------------------
# 自证：坏样本必须红、好样本必须绿、缺路必须 SKIP
# ---------------------------------------------------------------------------
function New-SchemaVariant {
    param([string]$SourcePath, [string]$DestinationPath, [scriptblock]$Mutate)
    $doc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($SourcePath, $script:Utf8NoBom))
    & $Mutate $doc
    $json = ConvertTo-Json -InputObject $doc -Depth 32
    [System.IO.File]::WriteAllText($DestinationPath, $json, $script:Utf8NoBom)
}

function Invoke-ParitySelfTest {
    param([string]$LeftPath)
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-parity-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    $assertions = New-Object System.Collections.Generic.List[object]

    function Add-Assertion {
        param([bool]$Ok, [string]$Label, [string]$Detail)
        $assertions.Add([pscustomobject]@{ Ok = $Ok; Label = $Label; Detail = $Detail })
    }

    try {
        # 好样本：语义等价的复制（重排缩进也算好样本，比较的是结构）
        $good = Join-Path $sandbox 'good.schema.json'
        New-SchemaVariant -SourcePath $LeftPath -DestinationPath $good -Mutate { param($d) }
        $r = Invoke-ParityGate -LeftPath $LeftPath -RightPath $good
        Add-Assertion ($r.Status -eq 'PASS') '好样本（等价复制）判 PASS：闸门不是一律红' ("status=$($r.Status) diffs=$(@($r.Diffs).Count)")

        # 坏样本 1：只改一个 enum 成员
        $badEnum = Join-Path $sandbox 'bad-enum.schema.json'
        New-SchemaVariant -SourcePath $LeftPath -DestinationPath $badEnum -Mutate { param($d) $d.properties.priority.enum = @('P0', 'P1', 'P9') }
        $r = Invoke-ParityGate -LeftPath $LeftPath -RightPath $badEnum
        $hit = (@($r.Diffs) -join "`n") -match '/properties/priority/enum'
        Add-Assertion (($r.Status -eq 'FAIL') -and $hit) '只改一个 enum 的坏样本判 FAIL，且点名 /properties/priority/enum' ("status=$($r.Status) named=$hit")

        # 坏样本 2：少一个属性键
        $badKey = Join-Path $sandbox 'bad-key.schema.json'
        New-SchemaVariant -SourcePath $LeftPath -DestinationPath $badKey -Mutate { param($d) $d.properties.PSObject.Properties.Remove('achievement') }
        $r = Invoke-ParityGate -LeftPath $LeftPath -RightPath $badKey
        $hit = (@($r.Diffs) -join "`n") -match 'properties/achievement'
        Add-Assertion (($r.Status -eq 'FAIL') -and $hit) '少一个属性键的坏样本判 FAIL，且点名 properties/achievement' ("status=$($r.Status) named=$hit")

        # 坏样本 3：翻 additionalProperties
        $badAp = Join-Path $sandbox 'bad-additional.schema.json'
        New-SchemaVariant -SourcePath $LeftPath -DestinationPath $badAp -Mutate { param($d) $d.additionalProperties = $false }
        $r = Invoke-ParityGate -LeftPath $LeftPath -RightPath $badAp
        $hit = (@($r.Diffs) -join "`n") -match '/additionalProperties'
        Add-Assertion (($r.Status -eq 'FAIL') -and $hit) 'additionalProperties 被翻成 false 判 FAIL' ("status=$($r.Status) named=$hit")

        # 坏样本 4：从 required 里删一个成员
        $badReq = Join-Path $sandbox 'bad-required.schema.json'
        New-SchemaVariant -SourcePath $LeftPath -DestinationPath $badReq -Mutate { param($d) $d.required = @('id', 'title', 'priority') }
        $r = Invoke-ParityGate -LeftPath $LeftPath -RightPath $badReq
        $hit = (@($r.Diffs) -join "`n") -match '/required'
        Add-Assertion (($r.Status -eq 'FAIL') -and $hit) 'required 少一个成员判 FAIL' ("status=$($r.Status) named=$hit")

        # 好样本 2：只改注释面，必须绿，且必须留 NOTE（不静默）
        $noteOnly = Join-Path $sandbox 'note-only.schema.json'
        New-SchemaVariant -SourcePath $LeftPath -DestinationPath $noteOnly -Mutate { param($d) $d.description = 'dsh-patrol 侧的说法：来源自 patrol-scaffold。' }
        $r = Invoke-ParityGate -LeftPath $LeftPath -RightPath $noteOnly
        Add-Assertion (($r.Status -eq 'PASS') -and (@($r.Notes).Count -ge 1)) '只改 description 判 PASS，但打印 NOTE（注释差异不静默）' ("status=$($r.Status) notes=$(@($r.Notes).Count)")

        # 缺路：按相对位置推出来的路径不存在 => SKIP；显式指路不存在 => FAIL
        $missing = Join-Path $sandbox 'no-such-dir\missing.schema.json'
        $rSkip = Invoke-ParityGate -LeftPath $LeftPath -RightPath $missing -SkipWhenRightMissing $true
        $rFail = Invoke-ParityGate -LeftPath $LeftPath -RightPath $missing -SkipWhenRightMissing $false
        Add-Assertion (($rSkip.Status -eq 'SKIP') -and ($rFail.Status -eq 'FAIL')) '缺路语义：默认路径缺失判 SKIP，显式指路缺失判 FAIL' ("skip=$($rSkip.Status) explicit=$($rFail.Status)")
    }
    finally {
        if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $selfPass = 0
    $selfFail = 0
    foreach ($a in $assertions) {
        if ($a.Ok) {
            $selfPass++
            Write-Host ('PASS selftest: {0}' -f $a.Label)
        }
        else {
            $selfFail++
            Write-Host ('FAIL selftest: {0}' -f $a.Label)
            if (-not [string]::IsNullOrWhiteSpace($a.Detail)) { Write-Host ('     {0}' -f $a.Detail) }
        }
    }
    return [pscustomobject]@{ pass = $selfPass; fail = $selfFail }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if (-not $Schema) { $Schema = Join-Path (Join-Path $repoRoot 'schemas') 'item.schema.json' }
$explicitOther = -not [string]::IsNullOrWhiteSpace($OtherSchema)
if (-not $explicitOther) {
    $OtherSchema = Join-Path (Join-Path (Split-Path -Parent $repoRoot) 'dsh-patrol') 'schemas/item.schema.json'
}

Write-Host 'item contract parity: patrol-scaffold <-> dsh-patrol item.schema.json (只读 / 离线)'
Write-Host ('left  = {0}' -f $Schema)
Write-Host ('right = {0} (source: {1})' -f $OtherSchema, $(if ($explicitOther) { 'explicit -OtherSchema' } else { 'repo-relative default' }))
Write-Host 'policy: 键集合 + 约束面逐键比较；required/enum/type 按集合；description/title 等注释面只 NOTE 不 FAIL'

$result = Invoke-ParityGate -LeftPath $Schema -RightPath $OtherSchema -SkipWhenRightMissing (-not $explicitOther)

$pass = 0; $fail = 0; $skip = 0
switch ($result.Status) {
    'PASS' {
        $pass++
        Write-Host ('PASS item-contract-parity: {0} 个约束叶子逐键相同' -f $result.Keys)
    }
    'SKIP' {
        $skip++
        Write-Host 'SKIP item-contract-parity'
        foreach ($d in $result.Diffs) { Write-Host ('     {0}' -f $d) }
        Write-Host '     本环境无从判定（CI 只 checkout 本仓 / 本机未 clone 兄弟仓），不计 FAIL 也不算 PASS'
    }
    'FAIL' {
        $fail++
        Write-Host 'FAIL item-contract-parity'
        foreach ($d in $result.Diffs) { Write-Host ('     {0}' -f $d) }
    }
}
foreach ($n in @($result.Notes)) { Write-Host ('NOTE {0}' -f $n) }

$exitCode = 0
if ($fail -gt 0) { $exitCode = 1 }

Write-Host ('summary pass={0} fail={1} skip={2}' -f $pass, $fail, $skip)

if ($NoSelfTest) {
    Write-Host 'selftest: skipped (-NoSelfTest)'
}
else {
    Write-Host '== selftest（临时目录里的样本自证）=='
    $self = Invoke-ParitySelfTest -LeftPath $Schema
    Write-Host ('summary selftest pass={0} fail={1}' -f $self.pass, $self.fail)
    if ($self.fail -gt 0) { $exitCode = 1 }
}

if ($exitCode -eq 0) { Write-Host ('RESULT: {0}' -f $result.Status) } else { Write-Host 'RESULT: FAIL' }
exit $exitCode
