#requires -Version 7
<#
.SYNOPSIS
  adapter-contract-test.ps1 — 适配器契约自测（Source Adapter 的护栏）。

.DESCRIPTION
  「更宽的适应性」要敢放宽 provider 面，前提是每个 provider 都被同一把尺子量过。
  对每个 adapters/*.adapter.json 依次执行：
    1) 装配（模块存在、list/write/resolve 三函数齐备）
    2) list-items() 实跑
    3) 每一行 item 过 schemas/item.schema.json
    4) resolve-name() 实跑且非空
    5) write-back() 只验存在与可调用（不真写源系统）
  需凭据的 provider（如 bitable）标 SKIP 而非 FAIL——那是配置问题，不是契约问题。

  注：校验用本文件自带的离线校验器，不用 Test-Json —— 它解析 JSON Schema 时会去拉
  meta-schema，离线环境会挂死。

.EXAMPLE
  pwsh -File scripts/adapter-contract-test.ps1
  pwsh -File scripts/adapter-contract-test.ps1 -Provider local-json -ReportPath reports/contract.json
#>
param(
    [string]$Provider = '',
    [string]$TasksFile = (Join-Path $PSScriptRoot 'sample-tasks.json'),
    [string]$ReportPath = '',
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'patrol-provider.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $repoRoot 'schemas\item.schema.json'
if (-not (Test-Path -LiteralPath $schemaPath)) { throw "schema not found: $schemaPath" }
$schema = ([System.IO.File]::ReadAllText($schemaPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)

function Test-PatrolSchemaType {
    param($Value, $TypeSpec)
    if ($null -eq $TypeSpec) { return $true }
    $types = @($TypeSpec)
    foreach ($t in $types) {
        switch ($t) {
            'null'   { if ($null -eq $Value) { return $true } }
            'string' { if ($Value -is [string]) { return $true } }
            'boolean'{ if ($Value -is [bool]) { return $true } }
            'integer'{ if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) { return $true } }
            'number' { if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $true } }
            'object' { if ($Value -is [pscustomobject] -or $Value -is [hashtable]) { return $true } }
            'array'  { if ($Value -is [array] -or $Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return $true } }
        }
    }
    return $false
}

function Test-PatrolItemSchema {
    # 返回违规清单（空数组 = 合规）。支持子集：type / required / enum / minimum / minLength
    param($Item, $SchemaDef)
    $violations = @()
    $props = @{}
    foreach ($p in $Item.PSObject.Properties) { $props[$p.Name] = $p.Value }

    foreach ($req in @($SchemaDef.required)) {
        if (-not $props.ContainsKey($req)) { $violations += "缺必填字段 '$req'" }
        elseif ($null -eq $props[$req]) { $violations += "必填字段 '$req' 为 null" }
    }
    foreach ($sp in $SchemaDef.properties.PSObject.Properties) {
        $name = $sp.Name
        if (-not $props.ContainsKey($name)) { continue }
        $val = $props[$name]
        if ($null -eq $val) { continue }
        $spec = $sp.Value
        if (-not (Test-PatrolSchemaType -Value $val -TypeSpec $spec.type)) {
            $violations += "字段 '$name' 类型不符（期望 $($spec.type -join '|')，实得 $($val.GetType().Name)）"
            continue
        }
        if ($spec.enum -and (@($spec.enum) -notcontains [string]$val)) {
            $violations += "字段 '$name' 取值 '$val' 不在 enum [$($spec.enum -join ',')]"
        }
        if ($null -ne $spec.minimum -and ($val -is [int] -or $val -is [long] -or $val -is [double]) -and $val -lt $spec.minimum) {
            $violations += "字段 '$name' 小于 minimum $($spec.minimum)"
        }
        if ($null -ne $spec.minLength -and $val -is [string] -and $val.Length -lt $spec.minLength) {
            $violations += "字段 '$name' 长度不足 $($spec.minLength)"
        }
    }
    return $violations
}

$adapterDir = Join-Path $repoRoot 'adapters'
if (-not (Test-Path -LiteralPath $adapterDir)) { throw "adapter dir not found: $adapterDir" }
$allDescriptors = @(Get-ChildItem -LiteralPath $adapterDir -Filter '*.adapter.json' | Sort-Object Name)
if ($allDescriptors.Count -eq 0) { throw "no adapter descriptor (*.adapter.json) found under $adapterDir" }

$descriptors = $allDescriptors
if ($Provider) {
    # 单 provider 用法兼容：先文件名精确匹配，再退回前缀匹配（老习惯 -Provider bit）
    $exact = @($allDescriptors | Where-Object { ($_.BaseName -replace '\.adapter$', '') -eq $Provider })
    if ($exact.Count -eq 0) { $exact = @($allDescriptors | Where-Object { $_.BaseName -like "$Provider*" }) }
    if ($exact.Count -eq 0) {
        $known = (@($allDescriptors | ForEach-Object { $_.BaseName -replace '\.adapter$', '' }) -join ', ')
        Write-Host ("[FAIL] provider '{0}'：adapters/ 下没有对应描述文件（已知 provider：{1}）" -f $Provider, $known)
        exit 1
    }
    $descriptors = $exact
}

$selected = (@($descriptors | ForEach-Object { $_.BaseName -replace '\.adapter$', '' }) -join ', ')
if (-not $Quiet) {
    Write-Host ("adapters: {0} 个 provider（{1}）" -f $descriptors.Count, $selected)
}

$results = @()
foreach ($file in $descriptors) {
    $name = $file.BaseName -replace '\.adapter$', ''
    $status = 'PASS'; $detail = ''; $count = 0; $errors = @()
    $moduleRel = ''
    try {
        # 描述文件与磁盘的一致性先查：模块缺失/键名不对要在装配前点名，不能等装配抛个含糊的错。
        # 注意：这几项与凭据无关，所以不能因为 needsCredentials 就 SKIP 掉（坏描述文件必须红）。
        $descriptorText = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false))
        $descriptor = $descriptorText | ConvertFrom-Json
        if ([string]$descriptor.provider -and [string]$descriptor.provider -ne $name) {
            throw "描述文件 provider='$($descriptor.provider)' 与文件名 '$($file.Name)' 不一致（装配按文件名找模块）"
        }
        $moduleRel = [string]$descriptor.module
        if (-not $moduleRel) { throw '描述文件缺 module 字段（找不到适配器模块）' }
        $moduleFull = Join-Path $repoRoot ($moduleRel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $moduleFull -PathType Leaf)) {
            throw "适配器模块不存在：$moduleRel（解析为 $moduleFull）"
        }

        $p = Import-PatrolProvider -Provider $name -Values @{ tasksFile = $TasksFile }

        # 缺函数必须点名报错：三个必选槽 + optional 里的能力型函数（后者只会在运行到该能力时才炸）
        foreach ($slot in @('listItems', 'writeBack', 'resolveName')) {
            $slotFn = [string]$p.Descriptor.$slot.function
            if (-not $slotFn) { throw "描述文件缺 $slot.function（契约函数必须点名）" }
            if (-not (Get-Command -Name $slotFn -CommandType Function -ErrorAction SilentlyContinue)) {
                throw "模块 $moduleRel 未定义 $slot.function '$slotFn'（契约不满足）"
            }
        }
        if ($p.Descriptor.optional) {
            foreach ($optProp in $p.Descriptor.optional.PSObject.Properties) {
                $optFn = [string]$optProp.Value.function
                if (-not $optFn) { throw "描述文件 optional.$($optProp.Name).function 为空" }
                if (-not (Get-Command -Name $optFn -CommandType Function -ErrorAction SilentlyContinue)) {
                    throw "模块 $moduleRel 未定义 optional.$($optProp.Name) 声明的函数 '$optFn'（到了该能力才炸的坑，这里提前报）"
                }
            }
        }

        $needsCred = [bool]$p.Descriptor.needsCredentials
        $cfgPath = [string]$p.Values.configPath
        if ($needsCred -and -not $cfgPath) {
            $status = 'SKIP'; $detail = "provider=$name 需凭据/配置（configPath 未给），跳过实跑"
        } else {
            $items = @(Get-PatrolProviderItems -Provider $p)
            $count = $items.Count
            if ($count -eq 0) { $status = 'FAIL'; $detail = 'list-items() 返回 0 行' }
            foreach ($it in $items) {
                foreach ($v in (Test-PatrolItemSchema -Item $it -SchemaDef $schema)) {
                    $status = 'FAIL'; $errors += "item '$($it.id)': $v"
                }
            }
            if ($items.Count -gt 0) {
                $nm = Resolve-PatrolProviderName -Provider $p -Item $items[0]
                if ([string]::IsNullOrWhiteSpace([string]$nm)) { $status = 'FAIL'; $errors += 'resolve-name() 返回空' }
            }
            $detail = "items=$count"
        }
    } catch {
        $status = 'FAIL'; $detail = $_.Exception.Message
    }
    if ($moduleRel) {
        if ($detail) { $detail = "$detail  module=$moduleRel" } else { $detail = "module=$moduleRel" }
    }
    $results += [pscustomobject]@{
        provider = $name; status = $status; items = $count; detail = $detail; module = $moduleRel; errors = @($errors)
    }
    if (-not $Quiet) {
        Write-Host ("[{0}] {1}  {2}" -f $status, $name, $detail)
        foreach ($e in $errors) { Write-Host ("      - {0}" -f $e) }
    }
}

$fail = @($results | Where-Object { $_.status -eq 'FAIL' })
$pass = @($results | Where-Object { $_.status -eq 'PASS' })
$skip = @($results | Where-Object { $_.status -eq 'SKIP' })
Write-Host ("summary pass={0} skip={1} fail={2}" -f $pass.Count, $skip.Count, $fail.Count)

if ($ReportPath) {
    $report = [pscustomobject]@{
        generatedAt = (Get-Date).ToString('o')
        schema = $schemaPath
        results = $results
        summary = [pscustomobject]@{ pass = $pass.Count; skip = $skip.Count; fail = $fail.Count }
    }
    $dir = Split-Path -Parent $ReportPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Write-Host "report: $ReportPath"
}
if ($fail.Count -gt 0) { exit 1 }