<#
    tests/verify-adapter-spec.ps1 — adapters/*.adapter.json 的规格漂移检查（只读 / 离线 / 零新依赖）

    对应 references/adapter-spec.md §10（插件注册/描述文件）与 §11（测试清单）的可执行版本。
    描述文件一旦与规格漂移——键名拼错、模块路径写死本机绝对路径、声明的函数在模块里根本不存在、
    args 里的 ${占位} 找不到 config 键——装配层只会在真实轮次里静默降级或晚到才炸。
    本脚本把这类漂移挡在提交前：只读、不跑写回、不联网、不引依赖。

    检查项：
      1) 必需键齐全 + 类型正确
         provider / title / module / kind / needsCredentials / needsNetwork / description /
         config / listItems / writeBack / resolveName
      2) provider 非空、全局唯一，且与文件名一致（<provider>.adapter.json）
      3) module 是相对仓库根的路径（不得是本机绝对路径 / 不得含 ..），且文件真实存在
      4) kind ∈ file | cli | api
      5) listItems / writeBack / resolveName 与 optional.<slot> 的 function 非空，
         且 dot-source 模块后该函数确实存在（只 dot-source，绝不调用它做写回）
      6) args 里的 ${...} 占位必须能在 config 中解析；${tasksFile} 例外
         （装配层 Import-PatrolProvider 统一注入 -Values @{ tasksFile = ... }）
      7) optional 必须是对象，optional.<slot> 必须是 { function, args }
      8) 【E-ARGNAME】每个槽位 args 的键名必须是该槽位 function 在 module 文件里
         真实声明的具名参数（逐字比较，大小写也算不同）。
         方向只查「args 键 ⊆ 函数具名参数」，不反查「函数的每个参数都必须出现在 args」——
         -Items / -Item 由装配层写死注入（asm: & $fn @args -Items $Items），
         反查会把 adapters/bitable.adapter.json 的 writeBack（只写 TasksFile）误判成红。
         参数表来自 PowerShell 自带 parser 的 AST（function ... param(...) 块），
         不是正则：跨行参数表、[Parameter(...)] 属性、默认值里的括号/字符串、
         注释里的 '( )' 都由 parser 配平；零新依赖、不执行模块。
         依据：装配层按参数名注入，键名写错时高级函数报「找不到与参数名称」、
         简单函数把多余具名参数静默收进 $args（不报错也不生效），
         两种都不会在真实轮次里被当成配置错误——所以要在提交前静态挡掉。

    规格没写死、这里定死并显式打印的两条口径：
      - 未知顶层键 => FAIL（不忽略）。理由：把 writeBack 拼成 "writeback" 时装配层会静默按默认值走，
        漂移检查就失去意义。确需扩展字段，先改 references/adapter-spec.md。
      - 缺 optional 键 => WARN（不 FAIL）。理由：装配层把 $null optional 当「无该能力」处理。

    自证：默认附带一段自测——在 %TEMP% 下造「3 条好样本 + 9 条坏样本」，断言每类规则都真的会红、
    好样本是绿的；临时目录 finally 删除，仓库零污染。关掉用 -NoSelfTest。
    args 键名闸门的自测是「3 负 + 2 正」：键名拼错 / 大小写不符 / 函数不存在（走 E-FUNC，不误报 E-ARGNAME）
    各一条；bitable 式「writeBack 只给部分参数」与「函数无具名参数 + args {}」各一条，必须绿。
    可重跑命令：pwsh -NoProfile -File tests/verify-adapter-spec.ps1（自测段随主流程一起跑）。

    运行环境：仅 PowerShell 7（pwsh）。本脚本与仓内其它 .ps1 一样存为 UTF-8 无 BOM；
    Windows PowerShell 5.1 会把无 BOM 中文按 ANSI 解码，连解析都过不去。脚本内保留的
    5.1 分支只用于解释旧输出，判红一律以 pwsh 7 为准。

.EXAMPLE
    pwsh -NoProfile -File tests/verify-adapter-spec.ps1
    pwsh -NoProfile -File tests/verify-adapter-spec.ps1 -AdapterDir D:\tmp\copy\adapters
#>
param(
    [string]$AdapterDir = '',
    [switch]$NoSelfTest
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $AdapterDir) { $AdapterDir = Join-Path $repoRoot 'adapters' }
if (-not (Test-Path -LiteralPath $AdapterDir -PathType Container)) {
    throw "verify-adapter-spec: adapter dir not found: $AdapterDir"
}
$AdapterDir = (Resolve-Path -LiteralPath $AdapterDir).Path
# module 字段相对「仓库根」解析；AdapterDir 的父目录就是那个根
$descriptorRoot = Split-Path -Parent $AdapterDir

# ---------------------------------------------------------------------------
# 规格定义
# ---------------------------------------------------------------------------
$script:RequiredKeys = [ordered]@{
    provider         = 'string'
    title            = 'string'
    module           = 'string'
    kind             = 'string'
    needsCredentials = 'bool'
    needsNetwork     = 'bool'
    description      = 'string'
    config           = 'object'
    listItems        = 'object'
    writeBack        = 'object'
    resolveName      = 'object'
}
$script:AllowedKinds = @('file', 'cli', 'api')
$script:KnownKeys = @($script:RequiredKeys.Keys) + @('optional')
$script:SlotNames = @('listItems', 'writeBack', 'resolveName')
$script:PlaceholderPattern = '\$\{([^}]+)\}'
$script:PlaceholderException = 'tasksFile'

function Test-SpecType {
    param($Value, [string]$Expected)
    switch ($Expected) {
        'string' { return ($Value -is [string]) }
        'bool'   { return ($Value -is [bool]) }
        'object' {
            return (($Value -is [System.Management.Automation.PSCustomObject]) -or
                    ($Value -is [hashtable]) -or
                    ($Value -is [System.Collections.IDictionary]))
        }
        'array' {
            return (($Value -is [array]) -or ($Value -is [System.Collections.IList]))
        }
        default { return $false }
    }
}

function Get-SpecTypeName {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return 'bool' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [array]) { return 'array' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    return $Value.GetType().Name
}

function Add-SpecIssue {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Rule,
        [string]$Message
    )
    if ($null -eq $List) { return }   # 注意：空 List 在 PowerShell 布尔上下文里是 $false，不能用 -not $List
    $List.Add(('[{0}] {1}' -f $Rule, $Message))
}

# args 占位校验：抽出来给三个槽和 optional.<slot> 共用
function Test-SpecArgPlaceholders {
    param(
        $ArgsSpec,
        [string]$SlotLabel,
        $ConfigKeys,
        [System.Collections.Generic.List[string]]$Errors
    )
    if (-not (Test-SpecType $ArgsSpec 'object')) {
        Add-SpecIssue $Errors 'E-TYPE' ("{0}.args 必须是对象（实得 {1}）" -f $SlotLabel, (Get-SpecTypeName $ArgsSpec))
        return
    }
    foreach ($ap in $ArgsSpec.PSObject.Properties) {
        if (-not ($ap.Value -is [string])) {
            Add-SpecIssue $Errors 'E-TYPE' ("{0}.args.{1} 必须是字符串（装配层按字符串注入；实得 {2}）" -f $SlotLabel, $ap.Name, (Get-SpecTypeName $ap.Value))
            continue
        }
        $found = [regex]::Matches($ap.Value, $script:PlaceholderPattern)
        if ($ap.Value.Contains('${') -and $found.Count -eq 0) {
            Add-SpecIssue $Errors 'E-PLACEHOLDER' ("{0}.args.{1} 的占位未闭合：'{2}'" -f $SlotLabel, $ap.Name, $ap.Value)
            continue
        }
        foreach ($m in $found) {
            $token = $m.Groups[1].Value
            if ($token -eq $script:PlaceholderException) { continue }
            if (-not ($ConfigKeys -contains $token)) {
                $available = '无'
                if ($null -ne $ConfigKeys -and @($ConfigKeys).Count -gt 0) { $available = (@($ConfigKeys) -join ', ') }
                if ($null -eq $ConfigKeys -or -not ($ConfigKeys -contains $token)) {
                    Add-SpecIssue $Errors 'E-PLACEHOLDER' ('{0}.args.{1} 的占位 ${{{2}}} 在 config 里找不到（config 可用键：{3}；唯一例外是 ${{tasksFile}}）' -f $SlotLabel, $ap.Name, $token, $available)
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 参数签名提取（E-ARGNAME 用）：只解析、不执行
# ---------------------------------------------------------------------------
function Get-AdapterFunctionSignatureMap {
    <#
        从 .ps1/.psm1 里抽出每个 function 的具名参数表。用 PowerShell 自带 parser 的 AST，
        而不是正则/手写扫描：param( 的括号配平、跨行参数表、[Parameter(...)] 属性、
        默认值里的括号与字符串、注释里的 '( )' 全部由 parser 负责，零新依赖。
        只看文件级 / if 等控制流里的函数定义（不进嵌套 scriptblock——那种定义不在模块作用域）。
        同名函数重复定义时：按文件顺序取最后一个（PowerShell 后定义者生效），并把名字记进 Duplicates。
    #>
    param([Parameter(Mandatory)][string]$ModulePath)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref]$tokens, [ref]$parseErrors)

    $map = @{}   # PowerShell 哈希表默认大小写不敏感，正好匹配「函数名不分大小写」
    $dups = New-Object System.Collections.Generic.List[string]
    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        # 语法错时参数表不可信；E-SYNTAX 已经在主流程报红
        return [pscustomobject]@{ Ok = $false; Functions = $map; Duplicates = $dups.ToArray() }
    }

    $fnAsts = $ast.FindAll({
            param($node)
            return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst])
        }, $false)

    foreach ($fd in $fnAsts) {
        $paramNames = New-Object System.Collections.Generic.List[string]
        # 注意：本仓写法是 function X { param(...) }，参数表挂在 Body.ParamBlock 上；
        # FunctionDefinitionAst.Parameters 只在个别旧写法下才有值，不能当唯一来源。
        $paramBlock = $null
        if ($null -ne $fd.Body) { $paramBlock = $fd.Body.ParamBlock }
        if ($null -ne $paramBlock) {
            foreach ($p in $paramBlock.Parameters) {
                # ParameterAst.Name 是 VariableExpressionAst；保留声明时的原始大小写
                $paramNames.Add($p.Name.VariablePath.UserPath)
            }
        }
        if ($map.ContainsKey($fd.Name)) { $dups.Add($fd.Name) }
        $map[$fd.Name] = [pscustomobject]@{
            Params = $paramNames.ToArray()
            Line   = $fd.Extent.StartLineNumber
        }
    }

    return [pscustomobject]@{ Ok = $true; Functions = $map; Duplicates = $dups.ToArray() }
}

function Test-SpecArgNames {
    <#
        闸门本体：args 的每个键必须是该槽位 function 真实声明的具名参数。
        只查单向（键 ⊆ 参数）：-Items / -Item 由装配层注入，不要求出现在 args 里。
        逐字比较（大小写敏感）：PowerShell 绑定虽不区分大小写，但描述文件是人工维护的契约，
        大小写漂移就是拼写错误的前兆，这里宁红不灰（口径见文件头）。
    #>
    param(
        $ArgsSpec,
        [string]$SlotLabel,
        [string]$FunctionName,
        $Signatures,
        [string]$ModuleRel,
        [string]$DescriptorFile,
        [System.Collections.Generic.List[string]]$Errors
    )
    if (-not (Test-SpecType $ArgsSpec 'object')) { return }              # E-TYPE 已报
    if (-not $FunctionName) { return }                                    # E-EMPTY 已报
    if ($null -eq $Signatures -or -not $Signatures.Ok) { return }         # 模块没解析出来，E-MODULE/E-SYNTAX 已报
    if (-not $Signatures.Functions.ContainsKey($FunctionName)) { return }  # E-FUNC 已报；没有参数表就不猜

    $decl = $Signatures.Functions[$FunctionName]
    $realNames = @($decl.Params)
    $realText = '（无具名参数）'
    if ($realNames.Count -gt 0) { $realText = '[' + ($realNames -join ', ') + ']' }

    foreach ($ap in $ArgsSpec.PSObject.Properties) {
        $exact = @($realNames | Where-Object { $_ -ceq $ap.Name })
        if ($exact.Count -gt 0) { continue }

        $why = '不在该函数的具名参数表里'
        $near = @($realNames | Where-Object { $_ -ieq $ap.Name })
        if ($near.Count -gt 0) { $why = ('大小写不符，真实参数是 ''{0}''' -f $near[0]) }

        Add-SpecIssue $Errors 'E-ARGNAME' (
            '{0}: {1}.args.{2} 不是函数 {3} 的具名参数（{4}；函数定义于 {5}:{6}；该函数真实参数：{7}）' -f
            $DescriptorFile, $SlotLabel, $ap.Name, $FunctionName, $why, $ModuleRel, $decl.Line, $realText)
    }
}

# ---------------------------------------------------------------------------
# 单个描述文件
# ---------------------------------------------------------------------------
function Test-SpecDescriptor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RelPath,
        [string]$Root,
        [hashtable]$ProviderCounts,
        [string]$FileProviderName
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $skips = New-Object System.Collections.Generic.List[string]
    $provider = ''
    $funcCount = 0

    $descriptor = $null
    try {
        $raw = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
        $descriptor = $raw | ConvertFrom-Json
    } catch {
        Add-SpecIssue $errors 'E-JSON' ("JSON 解析失败：{0}" -f $_.Exception.Message)
    }

    if ($null -eq $descriptor) {
        return [pscustomobject]@{
            file = $RelPath; provider = ''; status = 'FAIL'; funcs = 0
            errors = $errors; warnings = $warnings; skips = $skips
        }
    }
    if (-not (Test-SpecType $descriptor 'object')) {
        Add-SpecIssue $errors 'E-JSON' ("顶层必须是 JSON 对象（实得 {0}）" -f (Get-SpecTypeName $descriptor))
        return [pscustomobject]@{
            file = $RelPath; provider = ''; status = 'FAIL'; funcs = 0
            errors = $errors; warnings = $warnings; skips = $skips
        }
    }

    # 1) 必需键 + 类型
    foreach ($key in $script:RequiredKeys.Keys) {
        $prop = $descriptor.PSObject.Properties[$key]
        if (-not $prop) {
            Add-SpecIssue $errors 'E-REQ' ("缺必需键 '{0}'（规格 §10）" -f $key)
            continue
        }
        $expected = $script:RequiredKeys[$key]
        if (-not (Test-SpecType $prop.Value $expected)) {
            Add-SpecIssue $errors 'E-TYPE' ("键 '{0}' 类型不符（期望 {1}，实得 {2}）" -f $key, $expected, (Get-SpecTypeName $prop.Value))
        }
    }

    # 未知顶层键 => FAIL（口径见文件头）
    foreach ($prop in $descriptor.PSObject.Properties) {
        if ($script:KnownKeys -notcontains $prop.Name) {
            Add-SpecIssue $errors 'E-UNKNOWN' ("未知顶层键 '{0}'（strict：不忽略，防拼写漂移；已知键：{1}）" -f $prop.Name, ($script:KnownKeys -join ', '))
        }
    }

    # 2) provider：非空 / 与文件名一致 / 全局唯一
    if ($descriptor.provider -is [string]) { $provider = $descriptor.provider.Trim() }
    if (-not $provider) {
        if ($descriptor.PSObject.Properties['provider']) {
            Add-SpecIssue $errors 'E-EMPTY' 'provider 为空'
        }
    } else {
        if ($FileProviderName -and $provider -ne $FileProviderName) {
            Add-SpecIssue $errors 'E-FILENAME' ("provider='{0}' 与文件名 '{1}.adapter.json' 不一致（-Provider {0} 将找不到描述文件）" -f $provider, $FileProviderName)
        }
        if ($null -ne $ProviderCounts) {
            $n = 0
            if ($ProviderCounts.ContainsKey($provider)) { $n = [int]$ProviderCounts[$provider] }
            if ($n -gt 1) {
                Add-SpecIssue $errors 'E-DUP' ("provider='{0}' 在 {1} 个描述文件里重复（provider 必须唯一）" -f $provider, $n)
            }
        }
        if ($provider -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            Add-SpecIssue $warnings 'W-PROVIDER' ("provider='{0}' 含非常规字符（建议只用小写字母/数字/-/_）" -f $provider)
        }
    }

    # title / description
    if ($descriptor.title -is [string] -and -not $descriptor.title.Trim()) {
        Add-SpecIssue $errors 'E-EMPTY' 'title 为空'
    }
    if ($descriptor.description -is [string] -and -not $descriptor.description.Trim()) {
        Add-SpecIssue $warnings 'W-DESC' 'description 为空（建议一句话说明这个源是什么）'
    }

    # 4) kind
    if ($descriptor.kind -is [string] -and $descriptor.kind -and ($script:AllowedKinds -notcontains ([string]$descriptor.kind).Trim())) {
        Add-SpecIssue $errors 'E-ENUM' ("kind='{0}' 不在允许值 [{1}] 内" -f $descriptor.kind, ($script:AllowedKinds -join '|'))
    }

    # 3) module：相对路径 + 存在
    $moduleRel = ''
    $modulePath = $null
    if ($descriptor.module -is [string]) { $moduleRel = $descriptor.module.Trim() }
    if (-not $moduleRel) {
        if ($descriptor.PSObject.Properties['module']) {
            Add-SpecIssue $errors 'E-EMPTY' 'module 为空'
        }
    } elseif ($moduleRel -match '^[A-Za-z]:[\\/]' -or $moduleRel -match '^\\\\' -or $moduleRel -match '^/') {
        Add-SpecIssue $errors 'E-ABS' ("module 是本机绝对路径（{0}）：描述文件不得写死本机路径，改相对仓库根的路径" -f $moduleRel)
    } elseif ($moduleRel -match '(^|[\\/])\.\.([\\/]|$)') {
        Add-SpecIssue $errors 'E-ABS' ("module 含 '..'（{0}）：不得跳出仓库" -f $moduleRel)
    } else {
        $modulePath = Join-Path $Root ($moduleRel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            Add-SpecIssue $errors 'E-MODULE' ("module 不存在：{0}（解析为 {1}）" -f $moduleRel, $modulePath)
            $modulePath = $null
        } elseif ($moduleRel -notmatch '\.ps1$') {
            Add-SpecIssue $warnings 'W-MODULE' ("module 不是 .ps1：{0}" -f $moduleRel)
        }
    }

    # 参数签名表（供 E-ARGNAME）：只解析 AST，不执行模块；module 不可用时为 $null
    $signatures = $null
    if ($modulePath) { $signatures = Get-AdapterFunctionSignatureMap -ModulePath $modulePath }

    # config 键集合（供占位校验）
    $configKeys = $null
    if (Test-SpecType $descriptor.config 'object') {
        $configKeys = New-Object System.Collections.Generic.List[string]
        foreach ($cp in $descriptor.config.PSObject.Properties) {
            $configKeys.Add($cp.Name)
            $cv = $cp.Value
            if ($null -eq $cv) { continue }
            $isScalar = ($cv -is [string]) -or ($cv -is [bool]) -or ($cv -is [int]) -or ($cv -is [long]) -or
                        ($cv -is [double]) -or ($cv -is [decimal])
            if (-not $isScalar) {
                Add-SpecIssue $warnings 'W-CONFIG' ("config.{0} 不是标量（装配层会 [string] 强转）" -f $cp.Name)
                continue
            }
            if (($cv -is [string]) -and ($cv -match '^[A-Za-z]:[\\/]' -or $cv -match '^\\\\')) {
                Add-SpecIssue $warnings 'W-CONFIG' ("config.{0} 看起来是本机绝对路径（{1}）：默认值应可移植" -f $cp.Name, $cv)
            }
        }
    }

    # 5/6) 三个必选槽
    $declared = New-Object System.Collections.Generic.List[object]
    foreach ($slot in $script:SlotNames) {
        $prop = $descriptor.PSObject.Properties[$slot]
        if (-not $prop) { continue }               # 缺键已在 E-REQ 报过
        $spec = $prop.Value
        if (-not (Test-SpecType $spec 'object')) { continue }   # 类型错已在 E-TYPE 报过

        $fnName = ''
        if ($spec.function -is [string]) { $fnName = $spec.function.Trim() }
        if (-not $fnName) {
            Add-SpecIssue $errors 'E-EMPTY' ("{0}.function 为空（契约函数必须点名）" -f $slot)
        } else {
            $declared.Add([pscustomobject]@{ Slot = $slot; Name = $fnName })
        }

        if ($spec.PSObject.Properties['args']) {
            Test-SpecArgPlaceholders -ArgsSpec $spec.args -SlotLabel $slot -ConfigKeys $configKeys -Errors $errors
            Test-SpecArgNames -ArgsSpec $spec.args -SlotLabel $slot -FunctionName $fnName -Signatures $signatures `
                -ModuleRel $moduleRel -DescriptorFile $RelPath -Errors $errors
        }
    }

    # 7) optional
    $optProp = $descriptor.PSObject.Properties['optional']
    if (-not $optProp) {
        Add-SpecIssue $warnings 'W-OPTIONAL' '缺 optional 键（装配层按「无该能力」处理；规格要求写空对象 {}）'
    } elseif (-not (Test-SpecType $optProp.Value 'object')) {
        Add-SpecIssue $errors 'E-OPTIONAL' ("optional 必须是对象（实得 {0}）" -f (Get-SpecTypeName $optProp.Value))
    } else {
        foreach ($sp in $optProp.Value.PSObject.Properties) {
            $slotLabel = "optional.$($sp.Name)"
            $sub = $sp.Value
            if (-not (Test-SpecType $sub 'object')) {
                Add-SpecIssue $errors 'E-OPTIONAL' ("{0} 必须是对象 { function, args }（实得 {1}）" -f $slotLabel, (Get-SpecTypeName $sub))
                continue
            }
            $sfn = ''
            if ($sub.function -is [string]) { $sfn = $sub.function.Trim() }
            if (-not $sfn) {
                Add-SpecIssue $errors 'E-EMPTY' ("{0}.function 为空" -f $slotLabel)
            } else {
                $declared.Add([pscustomobject]@{ Slot = $slotLabel; Name = $sfn })
            }
            if ($sub.PSObject.Properties['args']) {
                Test-SpecArgPlaceholders -ArgsSpec $sub.args -SlotLabel $slotLabel -ConfigKeys $configKeys -Errors $errors
                Test-SpecArgNames -ArgsSpec $sub.args -SlotLabel $slotLabel -FunctionName $sfn -Signatures $signatures `
                    -ModuleRel $moduleRel -DescriptorFile $RelPath -Errors $errors
            }
        }
    }

    # 同名函数重复定义：参数表按「最后一个定义」判，但得让人知道判的是哪一份
    if ($signatures -and $signatures.Duplicates.Count -gt 0) {
        $dupDeclared = @($declared | Where-Object { $signatures.Duplicates -contains $_.Name } |
            ForEach-Object { '{0}({1})' -f $_.Name, $_.Slot })
        if ($dupDeclared.Count -gt 0) {
            Add-SpecIssue $warnings 'W-SIGNATURE' ('模块 {0} 里同一个函数被定义了多次（{1}）：E-ARGNAME 只按最后一个定义的参数表判，请先收口成一份' -f $moduleRel, ($dupDeclared -join ', '))
        }
    }

    # 5) dot-source 后函数是否真的存在（只读，不调用）
    $fnNames = @($declared | ForEach-Object { $_.Name } | Select-Object -Unique)
    $funcCount = $fnNames.Count
    if ($modulePath -and $fnNames.Count -gt 0) {
        # Windows PowerShell 5.1 按 ANSI 解码脚本：本仓模块是 UTF-8 无 BOM，中文会被吃字符并误报语法错。
        # 那不是「模块坏了」，记 SKIP 不判 FAIL（口径见文件头）。
        $encodingBlocked = $false
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $moduleBytes = [System.IO.File]::ReadAllBytes($modulePath)
            $hasBom = ($moduleBytes.Length -ge 3 -and $moduleBytes[0] -eq 0xEF -and $moduleBytes[1] -eq 0xBB -and $moduleBytes[2] -eq 0xBF)
            if (-not $hasBom) {
                foreach ($moduleByte in $moduleBytes) {
                    if ($moduleByte -ge 0x80) { $encodingBlocked = $true; break }
                }
            }
        }

        if ($encodingBlocked) {
            Add-SpecIssue $skips 'S-ENCODING' ("模块 {0} 是 UTF-8 无 BOM 且含非 ASCII：Windows PowerShell 5.1 按 ANSI 解码会误报语法错，{1} 个函数的存在性未检查（不计 FAIL）；请用 pwsh 7 校验，或给模块加 UTF-8 BOM" -f $moduleRel, $fnNames.Count)
        } else {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors -and @($parseErrors).Count -gt 0) {
                foreach ($pe in @($parseErrors)) {
                    Add-SpecIssue $errors 'E-SYNTAX' ("模块语法错误 {0}:{1} {2}" -f $moduleRel, $pe.Extent.StartLineNumber, $pe.Message)
                }
            } else {
                $needsVersion = $null
                if ($ast.ScriptRequirements -and $ast.ScriptRequirements.RequiredPSVersion) {
                    $needsVersion = $ast.ScriptRequirements.RequiredPSVersion
                }
                if ($needsVersion -and ($needsVersion -gt $PSVersionTable.PSVersion)) {
                    Add-SpecIssue $skips 'S-PSVERSION' ("模块声明 #requires -Version {0}，当前 PowerShell {1} 无法 dot-source：{2} 个函数的存在性未检查（不计 FAIL）" -f $needsVersion, $PSVersionTable.PSVersion, $fnNames.Count)
                } else {
                    $missing = $null
                    try {
                        $missing = & {
                            param([string]$ModulePath, [string[]]$Names)
                            $null = . $ModulePath
                            $out = New-Object System.Collections.Generic.List[string]
                            foreach ($n in $Names) {
                                $cmd = Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue
                                if (-not $cmd) { $out.Add($n) }
                            }
                            , $out.ToArray()
                        } $modulePath $fnNames
                    } catch {
                        Add-SpecIssue $errors 'E-MODULE' ("module 无法 dot-source：{0}（{1}）" -f $moduleRel, $_.Exception.Message)
                    }
                    if ($null -ne $missing) {
                        foreach ($m in @($missing)) {
                            if (-not $m) { continue }
                            $slotsHit = @($declared | Where-Object { $_.Name -eq $m } | ForEach-Object { $_.Slot }) -join ', '
                            Add-SpecIssue $errors 'E-FUNC' ("函数 '{0}' 在模块 {1} 里不存在（dot-source 后未定义；引用它的槽：{2}）" -f $m, $moduleRel, $slotsHit)
                        }
                    }
                }
            }
        }
    }

    $status = 'PASS'
    if ($errors.Count -gt 0) { $status = 'FAIL' }
    return [pscustomobject]@{
        file = $RelPath; provider = $provider; status = $status; funcs = $funcCount
        errors = $errors; warnings = $warnings; skips = $skips
    }
}

# ---------------------------------------------------------------------------
# 扫一个 adapters 目录
# ---------------------------------------------------------------------------
function Invoke-SpecCheck {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Root)

    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.adapter.json' | Sort-Object Name)
    if ($files.Count -eq 0) { throw "verify-adapter-spec: no *.adapter.json under $Dir" }

    # 先扫一遍 provider，才能判唯一性
    $providerCounts = @{}
    foreach ($f in $files) {
        try {
            $d = ([System.IO.File]::ReadAllText($f.FullName, $script:Utf8NoBom) | ConvertFrom-Json)
            if ($d -and ($d.provider -is [string]) -and $d.provider.Trim()) {
                $k = $d.provider.Trim()
                if ($providerCounts.ContainsKey($k)) { $providerCounts[$k] = [int]$providerCounts[$k] + 1 }
                else { $providerCounts[$k] = 1 }
            }
        } catch {
            # 解析失败留给逐文件检查报 E-JSON，这里只影响唯一性统计
        }
    }

    $dirName = Split-Path -Leaf $Dir
    $results = @()
    foreach ($f in $files) {
        $fileProvider = $f.BaseName -replace '\.adapter$', ''
        $rel = '{0}/{1}' -f $dirName, $f.Name
        $results += Test-SpecDescriptor -Path $f.FullName -RelPath $rel -Root $Root -ProviderCounts $providerCounts -FileProviderName $fileProvider
    }
    return , $results
}

function Write-SpecResults {
    param($Results, [string]$Title)
    Write-Host ('== {0} ==' -f $Title)
    foreach ($r in $Results) {
        $prov = $r.provider
        if (-not $prov) { $prov = '-' }
        Write-Host ('[{0}] {1}  provider={2} funcs={3}' -f $r.status, $r.file, $prov, $r.funcs)
        foreach ($e in $r.errors) { Write-Host ('        {0}' -f $e) }
        foreach ($w in $r.warnings) { Write-Host ('        {0}' -f $w) }
        foreach ($s in $r.skips) { Write-Host ('        {0}' -f $s) }
    }
}

# ---------------------------------------------------------------------------
# 自证：临时目录造「好样本 + 坏样本」，断言每类规则都会红
# ---------------------------------------------------------------------------
function Invoke-SpecSelfTest {

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-spec-selftest-' + [guid]::NewGuid().ToString('N'))
    $adapterDir = Join-Path $root 'adapters'
    $scriptDir = Join-Path $root 'scripts'
    try {
        New-Item -ItemType Directory -Path $adapterDir -Force | Out-Null
        New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null

        # 好模块：三函数齐备 + 一个「无 param 块」的函数 + 一个可选能力函数。
        # 刻意写成跨行参数表 / [Parameter(...)] 属性 / 默认值里带括号与引号，注释里再塞 '( )'，
        # 用来证明参数表是从 AST 抽的，而不是正则扫出来的。
        $goodModule = @'
function Get-PatrolItems {
    # list-items()：注释里带一个右括号 ) 和 param( 字样，提取不该被它带偏
    param(
        [Parameter(Mandatory)]
        [string]$TasksFile
    )
    return @()
}

function Save-PatrolItems {
    # write-back()：$Items 由装配层写死 -Items 注入，描述文件只写 TasksFile
    param(
        [Parameter(Mandatory)][string]$TasksFile,
        [Parameter(Mandatory)]$Items,
        [string]$Marker = ('(' + ')' + ')'),   # 默认值里带括号
        [string]$Note = "len=$($TasksFile.Length)"
    )
}

function Resolve-ItemName { param($Item) return 'sample' }

function Get-PatrolSummary {
    # 没有 param 块：只接受空 args
    return 'no-params'
}

function Sync-SelftestRound {
    param(
        [Parameter(Mandatory)][string]$TasksFile,
        [Parameter(Mandatory)]$Item,
        [string]$Identity = 'user'
    )
    return $true
}
'@
        [System.IO.File]::WriteAllText((Join-Path $scriptDir 'good-adapter.ps1'), $goodModule, $script:Utf8NoBom)

        # 好描述文件：必须判 PASS（证明校验器不是「一律红」）
        $goodDescriptor = @'
{
  "provider": "good",
  "title": "selftest good",
  "module": "scripts/good-adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest fixture",
  "config": { "tasksFile": "scripts/sample-tasks.json" },
  "listItems": { "function": "Get-PatrolItems", "args": { "TasksFile": "${tasksFile}" } },
  "writeBack": { "function": "Save-PatrolItems", "args": { "TasksFile": "${tasksFile}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'good.adapter.json'), $goodDescriptor, $script:Utf8NoBom)

        # 正例 A（对齐 bitable）：writeBack 只给 TasksFile，$Items 由装配层注入；
        #               optional.syncBack 只给 TasksFile，$Item 也是装配层注入。
        $goodPartialDescriptor = @'
{
  "provider": "good-partial",
  "title": "selftest good partial args",
  "module": "scripts/good-adapter.ps1",
  "kind": "cli",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest: args 只给部分参数，其余由装配层注入",
  "config": { "tasksFile": "scripts/sample-tasks.json" },
  "listItems": { "function": "Get-PatrolItems", "args": { "TasksFile": "${tasksFile}" } },
  "writeBack": { "function": "Save-PatrolItems", "args": { "TasksFile": "${tasksFile}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {
    "syncBack": { "function": "Sync-SelftestRound", "args": { "TasksFile": "${tasksFile}" } }
  }
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'good-partial.adapter.json'), $goodPartialDescriptor, $script:Utf8NoBom)

        # 正例 B：函数没有 param 块 + args {}（不应因「函数声明的参数为 0 个」误报）
        $goodNoArgsDescriptor = @'
{
  "provider": "good-noargs",
  "title": "selftest good no-param function",
  "module": "scripts/good-adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest: 函数无具名参数时 args 必须为空",
  "config": {},
  "listItems": { "function": "Get-PatrolItems", "args": {} },
  "writeBack": { "function": "Save-PatrolItems", "args": {} },
  "resolveName": { "function": "Get-PatrolSummary", "args": {} },
  "optional": {}
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'good-noargs.adapter.json'), $goodNoArgsDescriptor, $script:Utf8NoBom)

        # 负例 1：args 键名拼错（TaskFile -> TasksFile），高级函数实跑会报「找不到参数」
        $badArgDescriptor = @'
{
  "provider": "badarg",
  "title": "selftest arg name typo",
  "module": "scripts/good-adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest: args 键名拼错",
  "config": { "tasksFile": "scripts/sample-tasks.json" },
  "listItems": { "function": "Get-PatrolItems", "args": { "TaskFile": "${tasksFile}" } },
  "writeBack": { "function": "Save-PatrolItems", "args": { "TasksFile": "${tasksFile}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'badarg.adapter.json'), $badArgDescriptor, $script:Utf8NoBom)

        # 负例 2：大小写不符（tasksfile vs TasksFile）。PS 绑定不区分大小写，但描述文件要求逐字对齐
        $badCaseDescriptor = @'
{
  "provider": "badcase",
  "title": "selftest arg name case",
  "module": "scripts/good-adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest: args 键名大小写不符",
  "config": { "tasksFile": "scripts/sample-tasks.json" },
  "listItems": { "function": "Get-PatrolItems", "args": { "TasksFile": "${tasksFile}" } },
  "writeBack": { "function": "Save-PatrolItems", "args": { "tasksfile": "${tasksFile}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'badcase.adapter.json'), $badCaseDescriptor, $script:Utf8NoBom)

        # 负例 3：函数不存在 -> 走 E-FUNC，且不得跟着误报 E-ARGNAME（没参数表就不猜）
        $badFnDescriptor = @'
{
  "provider": "badfn",
  "title": "selftest function missing",
  "module": "scripts/good-adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest: 槽位函数不存在",
  "config": { "tasksFile": "scripts/sample-tasks.json" },
  "listItems": { "function": "Get-PatrolItemsMissing", "args": { "TasksFile": "${tasksFile}" } },
  "writeBack": { "function": "Save-PatrolItems", "args": { "TasksFile": "${tasksFile}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'badfn.adapter.json'), $badFnDescriptor, $script:Utf8NoBom)

        # 坏样本 1：类型 / 枚举 / 空函数名 / 未知键 / 占位不存在 / optional 非对象 / 缺键 / 函数不存在
        $brokenDescriptor = @'
{
  "provider": "broken",
  "title": 5,
  "module": "scripts/good-adapter.ps1",
  "kind": "weird",
  "needsCredentials": "yes",
  "description": "selftest broken",
  "config": [],
  "listItems": { "function": "", "args": {} },
  "writeBack": { "function": "Save-PatrolItemsMissing", "args": { "TasksFile": "${noSuchKey}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": [],
  "write_back": { "function": "Save-PatrolItems" }
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'broken.adapter.json'), $brokenDescriptor, $script:Utf8NoBom)

        # 坏样本 2：两个文件声明同一个 provider（而且都与文件名不一致）
        $twinTemplate = @'
{
  "provider": "twin",
  "title": "selftest twin",
  "module": "scripts/good-adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest duplicate provider",
  "config": {},
  "listItems": { "function": "Get-PatrolItems", "args": {} },
  "writeBack": { "function": "Save-PatrolItems", "args": {} },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'twin-a.adapter.json'), $twinTemplate, $script:Utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'twin-b.adapter.json'), $twinTemplate, $script:Utf8NoBom)

        # 坏样本 3：模块路径不存在
        $darkDescriptor = @'
{
  "provider": "dark",
  "title": "selftest dark",
  "module": "scripts/dark-adapter.ps1",
  "kind": "cli",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest missing module",
  "config": {},
  "listItems": { "function": "Get-PatrolItems", "args": {} },
  "writeBack": { "function": "Save-PatrolItems", "args": {} },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'dark.adapter.json'), $darkDescriptor, $script:Utf8NoBom)

        # 坏样本 4：module 写死本机绝对路径
        $absDescriptor = @'
{
  "provider": "abs",
  "title": "selftest abs",
  "module": "C:\\work\\adapter.ps1",
  "kind": "file",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "selftest absolute module path",
  "config": {},
  "listItems": { "function": "Get-PatrolItems", "args": {} },
  "writeBack": { "function": "Save-PatrolItems", "args": {} },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional": {}
}
'@
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'abs.adapter.json'), $absDescriptor, $script:Utf8NoBom)

        # 坏样本 5：JSON 语法错
        [System.IO.File]::WriteAllText((Join-Path $adapterDir 'badjson.adapter.json'), '{ "provider": "badjson", ', $script:Utf8NoBom)

        $results = Invoke-SpecCheck -Dir $adapterDir -Root $root

        foreach ($r in $results) {
            $ruleIds = @()
            foreach ($e in $r.errors) {
                $m = [regex]::Match($e, '^\[(E-[A-Z]+)\]')
                if ($m.Success -and ($ruleIds -notcontains $m.Groups[1].Value)) { $ruleIds += $m.Groups[1].Value }
            }
            $ruleText = 'ok'
            if ($ruleIds.Count -gt 0) { $ruleText = ($ruleIds -join ',') }
            Write-Host ('      fixture {0} -> {1} [{2}]' -f (Split-Path -Leaf $r.file), $r.status, $ruleText)
        }

        $assertions = New-Object System.Collections.Generic.List[object]
        $byFile = @{}
        foreach ($r in $results) { $byFile[(Split-Path -Leaf $r.file)] = $r }

        function Get-FixtureRules {
            param($Result)
            $ids = @()
            if ($null -ne $Result) {
                foreach ($e in @($Result.errors)) {
                    $m = [regex]::Match($e, '^\[(E-[A-Z]+)\]')
                    if ($m.Success -and ($ids -notcontains $m.Groups[1].Value)) { $ids += $m.Groups[1].Value }
                }
            }
            return $ids
        }

        $goodFixtures = @('good.adapter.json', 'good-partial.adapter.json', 'good-noargs.adapter.json')
        $greenMiss = @($goodFixtures | Where-Object { -not $byFile.ContainsKey($_) -or $byFile[$_].status -ne 'PASS' })
        $greenDetail = @($greenMiss | ForEach-Object {
                $errs = ''
                if ($byFile.ContainsKey($_)) { $errs = (@($byFile[$_].errors) -join ' | ') }
                '{0}: {1}' -f $_, $errs
            }) -join ' ; '
        $assertions.Add([pscustomobject]@{
            Ok = ($greenMiss.Count -eq 0)
            Label = ('正例全部判 PASS（{0} 条）' -f $goodFixtures.Count)
            Detail = ('未绿：{0}' -f $greenDetail)
        })

        # args 键名闸门的两个正例：单独断言，证明「只查 args 键 ⊆ 参数」而不是反查
        $partial = $byFile['good-partial.adapter.json']
        $partialRules = @(Get-FixtureRules $partial)
        $assertions.Add([pscustomobject]@{
            Ok = ($null -ne $partial -and $partial.status -eq 'PASS' -and $partialRules.Count -eq 0)
            Label = 'E-ARGNAME 正例：writeBack/optional 只给部分 args（-Items/-Item 由装配层注入）仍判 PASS'
            Detail = ('status={0} rules={1}' -f $partial.status, ($partialRules -join ','))
        })

        $noArg = $byFile['good-noargs.adapter.json']
        $noArgRules = @(Get-FixtureRules $noArg)
        $assertions.Add([pscustomobject]@{
            Ok = ($null -ne $noArg -and $noArg.status -eq 'PASS' -and $noArgRules.Count -eq 0)
            Label = 'E-ARGNAME 正例：函数无具名参数 + args {} 仍判 PASS'
            Detail = ('status={0} rules={1}' -f $noArg.status, ($noArgRules -join ','))
        })

        $brokenFiles = @($results | Where-Object { $goodFixtures -notcontains (Split-Path -Leaf $_.file) })
        $allRed = ($brokenFiles.Count -ge 5) -and (@($brokenFiles | Where-Object { $_.status -ne 'FAIL' }).Count -eq 0)
        $stillGreen = @($brokenFiles | Where-Object { $_.status -ne 'FAIL' } | ForEach-Object { $_.file }) -join ', '
        $assertions.Add([pscustomobject]@{ Ok = $allRed; Label = ('坏样本全部判 FAIL（{0} 个）' -f $brokenFiles.Count); Detail = ('未判红：{0}' -f $stillGreen) })

        # 负例 1：拼错的 args 键名必须判 E-ARGNAME，且报错要带描述文件/槽位/键名/函数名/真实参数表
        $typo = $byFile['badarg.adapter.json']
        $typoMsgs = @()
        if ($typo) { $typoMsgs = @($typo.errors | Where-Object { $_ -match '^\[E-ARGNAME\]' }) }
        $typoOk = ($null -ne $typo) -and ($typo.status -eq 'FAIL') -and ($typoMsgs.Count -eq 1) -and
            ($typoMsgs[0] -match 'badarg\.adapter\.json') -and
            ($typoMsgs[0] -match 'listItems\.args\.TaskFile') -and
            ($typoMsgs[0] -match 'Get-PatrolItems') -and
            ($typoMsgs[0] -match '真实参数：\[TasksFile\]')
        $typoDetail = '未出 E-ARGNAME'
        if ($typoMsgs.Count -gt 0) { $typoDetail = $typoMsgs[0] }
        $assertions.Add([pscustomobject]@{
            Ok = $typoOk
            Label = 'E-ARGNAME 负例：args 键名拼错（TaskFile）必须红且带真实参数表'
            Detail = $typoDetail
        })

        # 负例 2：仅大小写不同也必须红（逐字对齐比 PS 绑定更严）
        $caseRes = $byFile['badcase.adapter.json']
        $caseMsgs = @()
        if ($caseRes) { $caseMsgs = @($caseRes.errors | Where-Object { $_ -match '^\[E-ARGNAME\]' }) }
        $caseOk = ($null -ne $caseRes) -and ($caseRes.status -eq 'FAIL') -and ($caseMsgs.Count -eq 1) -and
            ($caseMsgs[0] -match 'writeBack\.args\.tasksfile') -and ($caseMsgs[0] -match '大小写不符')
        $caseDetail = '未出 E-ARGNAME'
        if ($caseMsgs.Count -gt 0) { $caseDetail = $caseMsgs[0] }
        $assertions.Add([pscustomobject]@{
            Ok = $caseOk
            Label = 'E-ARGNAME 负例：args 键名大小写不符（tasksfile）必须红并提示真实参数'
            Detail = $caseDetail
        })

        # 负例 3：函数不存在时走 E-FUNC，不得跟着误报 E-ARGNAME（没参数表就不猜）
        $fnRes = $byFile['badfn.adapter.json']
        $fnRules = @(Get-FixtureRules $fnRes)
        $fnOk = ($null -ne $fnRes) -and ($fnRes.status -eq 'FAIL') -and
            ($fnRules -contains 'E-FUNC') -and ($fnRules -notcontains 'E-ARGNAME')
        $assertions.Add([pscustomobject]@{
            Ok = $fnOk
            Label = 'E-ARGNAME 负例：槽位函数不存在时只报 E-FUNC（不误报 E-ARGNAME）'
            Detail = ('rules={0}' -f ($fnRules -join ','))
        })

        $seenRules = @()
        foreach ($r in $results) {
            foreach ($e in $r.errors) {
                $m = [regex]::Match($e, '^\[(E-[A-Z]+)\]')
                if ($m.Success -and ($seenRules -notcontains $m.Groups[1].Value)) { $seenRules += $m.Groups[1].Value }
            }
        }
        $expectedRules = @('E-JSON', 'E-REQ', 'E-TYPE', 'E-ENUM', 'E-EMPTY', 'E-DUP', 'E-FILENAME', 'E-ABS', 'E-MODULE', 'E-FUNC', 'E-PLACEHOLDER', 'E-OPTIONAL', 'E-UNKNOWN', 'E-ARGNAME')
        $missingRules = @($expectedRules | Where-Object { $seenRules -notcontains $_ })
        $assertions.Add([pscustomobject]@{
            Ok = ($missingRules.Count -eq 0)
            Label = ('每类规则都真的会红（{0}/{1}）' -f ($expectedRules.Count - $missingRules.Count), $expectedRules.Count)
            Detail = ('未触发：{0}' -f ($missingRules -join ', '))
        })
        Write-Host ('      selftest 命中的规则：{0}' -f (($seenRules | Sort-Object) -join ', '))
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $selfPass = 0
    $selfFail = 0
    foreach ($a in $assertions) {
        if ($a.Ok) {
            $selfPass++
            Write-Host ('PASS selftest: {0}' -f $a.Label)
        } else {
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
Write-Host 'adapters spec drift check (references/adapter-spec.md §10/§11, 只读)'
Write-Host ('adapterDir = {0}' -f $AdapterDir)
Write-Host 'policy: 未知顶层键 => FAIL（strict，防拼写漂移）; 缺 optional => WARN; ${...} 必须在 config 中，${tasksFile} 例外'
Write-Host 'policy: args 键名必须是该槽位 function 真实声明的具名参数（E-ARGNAME，逐字/大小写敏感；只查 args 键 ⊆ 参数）'

$results = Invoke-SpecCheck -Dir $AdapterDir -Root $descriptorRoot
Write-SpecResults -Results $results -Title 'adapters'

$passCount = @($results | Where-Object { $_.status -eq 'PASS' }).Count
$failCount = @($results | Where-Object { $_.status -eq 'FAIL' }).Count
$skipCount = @($results | Where-Object { @($_.skips).Count -gt 0 }).Count
$warnCount = 0
foreach ($r in $results) { $warnCount += @($r.warnings).Count }
Write-Host ('summary pass={0} fail={1} skip={2} warnings={3}' -f $passCount, $failCount, $skipCount, $warnCount)

$exitCode = 0
if ($failCount -gt 0) { $exitCode = 1 }

if ($NoSelfTest) {
    Write-Host 'selftest: skipped (-NoSelfTest)'
} else {
    Write-Host '== selftest（临时目录里的坏样本自证）=='
    $self = Invoke-SpecSelfTest
    Write-Host ('summary selftest pass={0} fail={1}' -f $self.pass, $self.fail)
    if ($self.fail -gt 0) { $exitCode = 1 }
}

if ($exitCode -eq 0) { Write-Host 'RESULT: PASS' } else { Write-Host 'RESULT: FAIL' }
exit $exitCode
