#requires -Version 7
<#
.SYNOPSIS
  verify-tencent-docs-adapter.ps1 — provider=tencent-docs 的端到端自测（无需真凭据）。

.DESCRIPTION
  起一个本地 mock 服务（tests/mock-tencent-docs.py）冒充腾讯文档 Smartsheet 记录接口，
  经 patrol-provider.ps1 的真实装配路径跑一遍：
    装配 -> 分页读取 -> 列映射 -> 阶段过滤 -> resolve-name -> 写本地镜像（远端零写入）
  任何一步不符预期即 FAIL，退出码 1。
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$mockPath = Join-Path $here 'mock-tencent-docs.py'
$port = 18923
$base = "http://127.0.0.1:$port"

. (Join-Path $root 'scripts\patrol-provider.ps1')

$pass = 0; $fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Label)
    if ($Condition) { Write-Host "PASS $Label"; $script:pass++ }
    else { Write-Host "FAIL $Label"; $script:fail++ }
}

$mock = Start-Process -FilePath 'python' -ArgumentList @($mockPath) -WindowStyle Hidden -PassThru
try {
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $probe = Invoke-WebRequest -Uri "$base/oauth/v2/app-account-token?x=1" -TimeoutSec 2 -ErrorAction Stop
            if ($probe.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    Assert-True $ready 'mock server answers'

    $tmpDir = Join-Path $env:TEMP ('tencent-docs-adapter-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $cfgPath = Join-Path $tmpDir 'tencent-docs.json'
    $mirrorPath = Join-Path $tmpDir 'mirror.json'
    $cfg = [ordered]@{
        apiBase       = $base
        fileId        = '300000000$MOCKFILE'
        sheetId       = 'BB0000'
        pageSize      = 2
        syncBack      = $false
        excludeStages = @('归档')
    }
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))

    $env:TENCENT_DOCS_CLIENT_ID = 'mock-client-id'
    $env:TENCENT_DOCS_CLIENT_SECRET = 'mock-client-secret'
    $env:TENCENT_DOCS_ACCESS_TOKEN = ''
    $env:TENCENT_DOCS_REFRESH_TOKEN = ''

    $provider = Import-PatrolProvider -Provider 'tencent-docs' -Values @{ configPath = $cfgPath; mirrorFile = $mirrorPath }
    $items = @(Get-PatrolProviderItems -Provider $provider)
    Assert-True ($items.Count -eq 2) "two pages read, archived row filtered (got $($items.Count))"
    Assert-True ($items[0].id -eq 'recAAA') 'recordID becomes item id'
    Assert-True ($items[0].title -eq '示例项目A-紧急') 'title maps 项目名'
    Assert-True ($items[0].repoPath -eq 'D:\gitAll\demo-a') 'repoPath maps 仓库路径'
    Assert-True ($items[0].priority -eq 'P0') 'priority normalised to upper case'
    Assert-True ($items[0].intervalMin -eq 30) 'interval maps 巡检间隔(分钟)'
    Assert-True ($items[1].id -eq 'recCCC') 'second page record present'
    Assert-True ($items[1].lastRun -like '2025-*' -or $items[1].lastRun -like '2026-*') 'epoch millis converted to ISO time'

    $nm = Resolve-PatrolProviderName -Provider $provider -Item $items[0]
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$nm)) 'resolve-name returns a label'

    Save-PatrolProviderItems -Provider $provider -Items $items | Out-Null
    Assert-True (Test-Path -LiteralPath $mirrorPath) 'write-back writes the local mirror'
    $mirror = @(Get-Content -LiteralPath $mirrorPath -Raw | ConvertFrom-Json)
    Assert-True ($mirror.Count -eq 2) 'mirror holds both items'

    $bytes = [System.IO.File]::ReadAllBytes($mirrorPath)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'mirror has no BOM'

    $leak = Select-String -LiteralPath $mirrorPath -Pattern 'mock-client-secret|mock-token' -Quiet -ErrorAction SilentlyContinue
    Assert-True (-not $leak) 'mirror contains no credentials'

    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:TENCENT_DOCS_CLIENT_SECRET -ErrorAction SilentlyContinue
    Remove-Item Env:TENCENT_DOCS_CLIENT_ID -ErrorAction SilentlyContinue
}

Write-Host "summary pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
