#requires -Version 7
<#
    tests/verify-doc-gate-claims.ps1 — 写回「双门」口径 ↔ 实现的漂移闸门（离线，无凭据、无网络）。

    背景：2026-11 修过一次幽灵开关——散文里把 bitable 写回描述成「config.sync_back + 显式 -SyncBack 双门」，
    而 Sync-BitableRoundResult 的签名只有 BitableConfigPath / Item / Identity，-SyncBack 是从旧实现带过来的记忆。
    描述文件那一层的键名漂移已被 verify-adapter-spec.ps1 的 E-ARGNAME 挡住（args 键 ⊆ 函数具名参数），
    但散在 README / SKILL / AGENTS / CHANGELOG / references / adapters 里的散文口径没人守——
    同一个谎可以再写一遍，测试全绿。本脚本补的就是这块：钉实现事实 + 禁幽灵开关回潮 + 自证会判红。

    四件事：
      1) 实现事实：AST 读 Sync-BitableRoundResult 的具名参数，必须恰好是 BitableConfigPath / Item / Identity
      2) 文案不回流：同时出现该函数名与 `-SyncBack` 的段落/表格行，必须带显式否定词，否则判红
      3) 规则不空转：喂「旧文案原文」必须判红；喂「已改正文案」必须绿（判红/判绿成对，缺一不算证据）
      4) 规则不一刀切：tencent-docs 的 Save-PatrolItems 真声明了 -SyncBack（AST）+ 描述文件真映射它，
         证明 -SyncBack 这个词本身合法，只有挂在 bitable 头上才算漂移
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Label, [string]$Detail)
    if ($Condition) { Write-Host "PASS $Label"; $script:pass++ }
    else {
        Write-Host "FAIL $Label"
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "     $Detail" }
        $script:fail++
    }
}

function Get-FunctionParamNames {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw ("解析失败 {0}: {1}" -f $Path, $errors[0].Message) }
    $fn = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $fn) { return $null }
    if (-not $fn.Body.ParamBlock) { return @() }
    return @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

# 「幽灵开关」扫描器：段落级（空行切分），但表格行各自成段——否则整张表的否定词会借给隔壁一行。
# 判定：同一单元里出现 `-SyncBack` 且话题是 bitable（提 bitable / 提 Sync-BitableRoundResult），
# 又没有显式否定词 = 漂移。看清这一点很重要：真实的漂移原句里并没有函数名
# （`All Bitable writes are gated by both config (sync_back=true) AND CLI flag (-SyncBack)` /
#  README 行的 `受 sync_back + 显式 -SyncBack 双门控制`），只按函数名匹配等于放过真凶。
function Get-GhostSwitchClaims {
    param([string]$Text, [string]$Source)
    $negation = '没有|不含|不存在|不该|不得|不许|别写|禁止|不用|不带|不走|不接|不认|无\s*\*{0,2}\s*`?-SyncBack|(?<![A-Za-z])no(?![A-Za-z])'
    $hits = @()
    foreach ($para in [regex]::Split($Text, "(?:\r?\n[ \t]*){2,}")) {
        $units = if ($para -match '(?m)^\s*\|') { $para -split "\r?\n" } else { @($para) }
        foreach ($unit in $units) {
            if ($unit -notmatch '(?i)bitable') { continue }
            if ($unit -notmatch '(?<![A-Za-z])-SyncBack(?![A-Za-z])') { continue }
            if ($unit -match $negation) { continue }
            # 开关被明确归给别家（tencent-docs / 腾讯文档，紧随其后 40 字内）的句子，不算 bitable 的文案
            if ($unit -match '(?i)(tencent-docs|腾讯文档)[^\n\u3002\uff1b]{0,40}-SyncBack') { continue }
            $hits += [pscustomobject]@{ Source = $Source; Text = ($unit -replace '\s+', ' ').Trim() }
        }
    }
    return $hits
}

try {
    $adapterPath = Join-Path $repoRoot 'scripts\BitAbleAdapter.ps1'
    $txPath = Join-Path $repoRoot 'scripts\tencent-docs-adapter.ps1'

    # ---- 1) 实现事实：签名里没有 -SyncBack ----
    $bitableParams = Get-FunctionParamNames -Path $adapterPath -Name 'Sync-BitableRoundResult'
    Assert-True ($null -ne $bitableParams) '1) scripts/BitAbleAdapter.ps1 里有 Sync-BitableRoundResult'
    $bitableParams = @($bitableParams)
    Assert-True (($bitableParams -join ',') -eq 'BitableConfigPath,Item,Identity') `
        ('1) Sync-BitableRoundResult 具名参数恰好 BitableConfigPath/Item/Identity（实得 {0}）' -f ($bitableParams -join ','))
    Assert-True (-not ($bitableParams -contains 'SyncBack')) `
        ('1) 签名里没有 SyncBack —— 文案不得声称有这个开关（实得 {0}）' -f ($bitableParams -join ','))

    # ---- 2) 文案不回流：扫入口文档 + 描述文件 ----
    $docPaths = @(
        Join-Path $repoRoot 'AGENTS.md'
        Join-Path $repoRoot 'README.md'
        Join-Path $repoRoot 'SKILL.md'
        Join-Path $repoRoot 'CHANGELOG.md'
    )
    foreach ($dir in @('docs', 'references')) {
        $p = Join-Path $repoRoot $dir
        if (Test-Path -LiteralPath $p) { $docPaths += @(Get-ChildItem -LiteralPath $p -Filter *.md -File -Recurse | ForEach-Object { $_.FullName }) }
    }
    $adapterDir = Join-Path $repoRoot 'adapters'
    $docPaths += @(Get-ChildItem -LiteralPath $adapterDir -Filter *.json -File | ForEach-Object { $_.FullName })
    $docPaths = @($docPaths | Where-Object { Test-Path -LiteralPath $_ })
    Assert-True ($docPaths.Count -ge 8) ('2) 扫描面覆盖 {0} 份文档/描述文件' -f $docPaths.Count)

    $claims = @()
    $mentions = 0
    foreach ($docPath in $docPaths) {
        $text = [System.IO.File]::ReadAllText($docPath, [System.Text.UTF8Encoding]::new($false))
        if ($text -match '(?i)bitable') { $mentions++ }
        $claims += @(Get-GhostSwitchClaims -Text $text -Source (Split-Path -Leaf $docPath))
    }
    Assert-True ($mentions -ge 4) ('2) 有 {0} 份文档在讲这个函数（覆盖不是空集）' -f $mentions)
    $claimDetail = ($claims | ForEach-Object { '{0}: {1}' -f $_.Source, $_.Text }) -join ' ;; '
    Assert-True ($claims.Count -eq 0) ('2) 没有段落把 -SyncBack 说成 Sync-BitableRoundResult 的开关（命中 {0} 处）' -f $claims.Count) $claimDetail

    # ---- 3) 规则不空转：历史漂移原文必须判红，改正后的同一句必须判绿 ----
    # 两段原文逐字取自被修掉的那两处（commit 45f269d 的 BitAbleAdapter.ps1 头注释、README 表格行），
    # 都不带函数名——这正是「只匹配函数名会放过真凶」的证据。
    $oldClaims = @{
        'fixture/old-header' = 'All Bitable writes are gated by both config (`sync_back=true`) AND CLI flag (`-SyncBack`). Default behavior is read-only.'
        'fixture/old-readme' = '| `bitable` | cli | 需要（`lark-cli` + config）/ 需要 | 受 `sync_back` + 显式 `-SyncBack` 双门控制 |'
    }
    foreach ($k in $oldClaims.Keys) {
        $hits = @(Get-GhostSwitchClaims -Text $oldClaims[$k] -Source $k)
        Assert-True ($hits.Count -eq 1) ('3) 历史漂移原文判红：{0}（实得 {1} 处）' -f $k, $hits.Count)
    }
    $fixedClaim = '写回受 `config.sync_back` 双门控制；`Sync-BitableRoundResult` 没有 `-SyncBack` 参数，显式触发在 `patrol-writeback.ps1 -Apply`。'
    $fixedHits = @(Get-GhostSwitchClaims -Text $fixedClaim -Source 'fixture/fixed')
    Assert-True ($fixedHits.Count -eq 0) ('3) 改正后的文案判绿（实得 {0} 处）' -f $fixedHits.Count) (($fixedHits | ForEach-Object { $_.Text }) -join ' ;; ')
    # 相邻表格行不许借否定词：上一行说「没有」，下一行新长出一个幽灵开关仍要判红
    $sneaky = @'
| `bitable` | `Sync-BitableRoundResult` 没有 `-SyncBack` 参数 |
| `bitable` | `Sync-BitableRoundResult` 受 `-SyncBack` 开关控制 |
'@
    Assert-True (@(Get-GhostSwitchClaims -Text $sneaky -Source 'fixture/table').Count -eq 1) '3) 表格里相邻行的否定词不外溢（仍判红 1 处）'

    # ---- 4) 不一刀切：tencent-docs 的 -SyncBack 是合法参数，用它做正例对照 ----
    $txParams = Get-FunctionParamNames -Path $txPath -Name 'Save-PatrolItems'
    Assert-True ($null -ne $txParams -and (@($txParams) -contains 'SyncBack')) `
        ('4) tencent-docs 的 Save-PatrolItems 真声明了 SyncBack（实得 {0}）' -f ((@($txParams) -join ',')))
    $txDesc = Get-Content -LiteralPath (Join-Path $adapterDir 'tencent-docs.adapter.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$txDesc.writeBack.args.SyncBack -eq '${syncBack}') `
        ('4) tencent-docs 描述文件把 -SyncBack 映射成占位符（实得 {0}）' -f [string]$txDesc.writeBack.args.SyncBack)
    $txDocHit = @(Get-GhostSwitchClaims -Text '`tencent-docs` 的 `Save-PatrolItems -SyncBack` 是一道显式门。' -Source 'fixture/tx')
    Assert-True ($txDocHit.Count -eq 0) '4) 讲 tencent-docs 的 -SyncBack 不误判（规则只咬 bitable 的文案）'
    $cmpDocHit = @(Get-GhostSwitchClaims -Text '`bitable` 只判 `sync_back`；`tencent-docs` 另有 `Save-PatrolItems -SyncBack`，两家形态不同。' -Source 'fixture/cmp')
    Assert-True ($cmpDocHit.Count -eq 0) '4) 对比句（开关归给 tencent-docs）不误判'

    # ---- 5) 必须写的口径：入口文档要同时给出两道门的名字 ----
    foreach ($rel in @('AGENTS.md', 'README.md', 'SKILL.md', 'references\adding-a-provider.md', 'adapters\bitable.adapter.json')) {
        $p = Join-Path $repoRoot $rel
        $t = [System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($t -match 'optional\.syncBack' -and $t -match 'sync_?[Bb]ack') `
            ('5) {0} 写清了两道门（optional.syncBack + sync_back）' -f $rel)
    }
} catch {
    $fail++
    Write-Host ('FAIL exception: {0}' -f $_.Exception.Message)
}

Write-Host ('summary pass={0} fail={1}' -f $pass, $fail)
if ($fail -gt 0) { Write-Host 'RESULT: FAIL'; exit 1 }
Write-Host 'RESULT: PASS'
exit 0
