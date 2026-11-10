#requires -Version 7
<#
.SYNOPSIS
  patrol-provider.ps1 — 源适配器装配层（Source Adapter 的统一入口）。

.DESCRIPTION
  本文件是「更宽的适应性」的落地件：换数据源 = 落一个 adapters/<provider>.adapter.json
  描述文件 + 一个模块脚本，**patrol-loop.ps1 一行不改**。

  描述文件（adapters/*.adapter.json）声明：
    provider / module / kind / needsCredentials / needsNetwork / config
    listItems { function, args }   -> list-items()
    writeBack { function, args }   -> write-back()
    resolveName { function, args } -> resolve-name()
    optional  { <slot> { function, args } }  可选能力（如 bitable 的 syncBack）

  args 里可用 ${token} 占位，由调用方 -Values 注入（如 ${tasksFile} / ${configPath}）。

.EXAMPLE
  $p = Import-PatrolProvider -Provider 'local-json' -Values @{ tasksFile = 'scripts/sample-tasks.json' }
  $items = @(Get-PatrolProviderItems -Provider $p)
#>

$script:PatrolRepoRoot = Split-Path -Parent $PSScriptRoot

function Get-PatrolAdapterDescriptor {
    # 读取 adapters/<provider>.adapter.json（契约声明的唯一入口）
    param([Parameter(Mandatory)][string]$Provider)
    $path = Join-Path $script:PatrolRepoRoot ("adapters\{0}.adapter.json" -f $Provider)
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Get-PatrolAdapterDescriptor: adapter descriptor not found: $path"
    }
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
    return ($raw | ConvertFrom-Json)
}

function Expand-PatrolAdapterArgs {
    # 把 args 里的 ${token} 换成实值
    param($ArgSpec, [hashtable]$Values)
    $out = @{}
    if ($null -eq $ArgSpec) { return $out }
    foreach ($p in $ArgSpec.PSObject.Properties) {
        $v = [string]$p.Value
        if ($Values) {
            foreach ($k in @($Values.Keys)) {
                $v = $v.Replace('${' + $k + '}', [string]$Values[$k])
            }
        }
        $out[$p.Name] = $v
    }
    return $out
}

function Import-PatrolProvider {
    # 装配一个 provider：读描述 -> dot-source 模块 -> 校验三个契约函数存在
    param(
        [Parameter(Mandatory)][string]$Provider,
        [hashtable]$Values = @{}
    )
    $d = Get-PatrolAdapterDescriptor -Provider $Provider

    $moduleRel = [string]$d.module
    if (-not $moduleRel) { throw "Import-PatrolProvider: descriptor '$Provider' 缺 module" }
    $modulePath = Join-Path $script:PatrolRepoRoot ($moduleRel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Import-PatrolProvider: adapter module not found: $modulePath"
    }
    . $modulePath
    # dot-source 发生在函数作用域，函数会随本函数退出而消失——须提升到脚本作用域，
    # 否则返回后 Get-PatrolProviderItems 找不到契约函数。
    $fnNames = @()
    foreach ($slot in @('listItems', 'writeBack', 'resolveName')) {
        $spec0 = $d.$slot
        if ($spec0 -and $spec0.function) { $fnNames += [string]$spec0.function }
    }
    if ($d.optional) {
        foreach ($prop in $d.optional.PSObject.Properties) {
            if ($prop.Value -and $prop.Value.function) { $fnNames += [string]$prop.Value.function }
        }
    }
    foreach ($fnName in ($fnNames | Select-Object -Unique)) {
        $cmd = Get-Command -Name $fnName -CommandType Function -ErrorAction SilentlyContinue
        if ($cmd) { Set-Item -Path ("function:script:{0}" -f $fnName) -Value $cmd.ScriptBlock }
    }

    foreach ($slot in @('listItems', 'writeBack', 'resolveName')) {
        $spec = $d.$slot
        if ($null -eq $spec -or -not $spec.function) {
            throw "Import-PatrolProvider: descriptor '$Provider' 缺 $slot.function"
        }
        if (-not (Get-Command -Name $spec.function -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Import-PatrolProvider: 模块 $moduleRel 未定义 $($spec.function)（契约不满足）"
        }
    }

    # 合并取值：descriptor 默认 < 环境变量 < 显式 -Values
    $merged = @{}
    if ($d.config) {
        foreach ($p in $d.config.PSObject.Properties) { $merged[$p.Name] = [string]$p.Value }
    }
    foreach ($k in @($Values.Keys)) {
        if ($null -ne $Values[$k] -and [string]$Values[$k] -ne '') { $merged[$k] = [string]$Values[$k] }
    }
    foreach ($k in @($merged.Keys)) {
        $envKey = 'PATROL_' + ($Provider -replace '[^A-Za-z0-9]', '_').ToUpper() + '_' + ($k -replace '[^A-Za-z0-9]', '_').ToUpper()
        $envVal = [Environment]::GetEnvironmentVariable($envKey)
        if ($envVal) { $merged[$k] = $envVal }
    }

    return [pscustomobject]@{
        Provider   = $Provider
        Descriptor = $d
        ModulePath = $modulePath
        Values     = $merged
    }
}

function ConvertTo-PatrolItem {
    # 把适配器吐出的任意形状归一成规范 item（契约边界唯一收口点）。
    # 典型坑：ConvertFrom-Json 会把 ISO 时间串自动转成 [DateTime]，与 schema 的 string 冲突。
    param([Parameter(Mandatory)]$Item)
    $o = [ordered]@{}
    foreach ($prop in $Item.PSObject.Properties) { $o[$prop.Name] = $prop.Value }

    $id = if ($null -ne $o['id']) { [string]$o['id'] } else { '' }
    $title = if ($null -ne $o['title']) { [string]$o['title'] } else { '' }
    if (-not $id) { throw 'ConvertTo-PatrolItem: item 缺 id' }
    if (-not $title) { $title = $id }

    $priority = if ($null -ne $o['priority']) { ([string]$o['priority']).Trim().ToUpperInvariant() } else { 'P2' }
    if ($priority -notin @('P0', 'P1', 'P2')) { $priority = 'P2' }

    $interval = 0
    if ($null -ne $o['intervalMin']) { try { $interval = [int]$o['intervalMin'] } catch { $interval = 0 } }
    if ($interval -lt 0) { $interval = 0 }

    $lastRun = $o['lastRun']
    if ($lastRun -is [datetime]) { $lastRun = $lastRun.ToString('o') }
    elseif ($lastRun -is [datetimeoffset]) { $lastRun = $lastRun.ToString('o') }
    elseif ($null -ne $lastRun -and -not ($lastRun -is [string])) { $lastRun = [string]$lastRun }
    if ([string]::IsNullOrWhiteSpace([string]$lastRun)) { $lastRun = $null }

    $threadId = if ($null -ne $o['threadId'] -and [string]$o['threadId']) { [string]$o['threadId'] } else { $null }
    $fake = $false
    if ($null -ne $o['fake']) { $fake = [bool]$o['fake'] }

    $out = [ordered]@{
        id = $id
        title = $title
        repoPath = if ($null -ne $o['repoPath']) { [string]$o['repoPath'] } else { '' }
        description = if ($null -ne $o['description']) { [string]$o['description'] } else { '' }
        nextStep = if ($null -ne $o['nextStep']) { [string]$o['nextStep'] } else { '' }
        priority = $priority
        intervalMin = $interval
        threadId = $threadId
        fake = $fake
        lastRun = $lastRun
        currentStage = if ($null -ne $o['currentStage']) { [string]$o['currentStage'] } else { '' }
        achievement = if ($null -ne $o['achievement']) { [string]$o['achievement'] } else { '' }
    }
    foreach ($k in $o.Keys) { if (-not $out.Contains($k)) { $out[$k] = $o[$k] } }
    return [pscustomobject]$out
}

function Get-PatrolProviderItems {
    # list-items()
    param(
        [Parameter(Mandatory)]$Provider,
        [hashtable]$Extra = @{}
    )
    $spec = $Provider.Descriptor.listItems
    $vals = @{} + $Provider.Values + $Extra
    $args = Expand-PatrolAdapterArgs -ArgSpec $spec.args -Values $vals
    foreach ($k in @($args.Keys)) {
        if (-not $args[$k]) { throw "Get-PatrolProviderItems: provider=$($Provider.Provider) 必填参数 '$k' 为空（描述文件声明为必填）" }
    }
    $fn = $spec.function
    # 契约边界收口：适配器吐什么都先归一，再交给调度器
    return @(@(& $fn @args) | ForEach-Object { ConvertTo-PatrolItem -Item $_ })
}

function Save-PatrolProviderItems {
    # write-back()
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)]$Items,
        [hashtable]$Extra = @{}
    )
    $spec = $Provider.Descriptor.writeBack
    $vals = @{} + $Provider.Values + $Extra
    $args = Expand-PatrolAdapterArgs -ArgSpec $spec.args -Values $vals
    $fn = $spec.function
    return (& $fn @args -Items $Items)
}

function Resolve-PatrolProviderName {
    # resolve-name()
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)]$Item
    )
    $spec = $Provider.Descriptor.resolveName
    $args = Expand-PatrolAdapterArgs -ArgSpec $spec.args -Values $Provider.Values
    $fn = $spec.function
    return (& $fn @args -Item $Item)
}

function Sync-PatrolProviderRoundResult {
    # optional 能力（当前只有 bitable 的 syncBack）；描述文件没声明就返回 $false
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)]$Item,
        [hashtable]$Extra = @{}
    )
    $opt = $Provider.Descriptor.optional
    if ($null -eq $opt -or $null -eq $opt.syncBack) { return $false }
    $vals = @{} + $Provider.Values + $Extra
    $args = Expand-PatrolAdapterArgs -ArgSpec $opt.syncBack.args -Values $vals
    $fn = $opt.syncBack.function
    return (& $fn @args -Item $Item)
}