#requires -Version 7
<#
    tests/verify-interval-zero-claims.ps1 — 「interval=0 = 停跑」口径 ↔ 实现的漂移闸门（离线，无凭据、无网络）。

    背景：2026-11 把调度语义从「`<=0` 回退 60 分钟」改成「0 / 空 / 缺列 / 负数 = 停跑（disabled）」。
    tests/verify-disabled-scheduling.ps1 只钉运行时行为（喂 fixture 看 due/disabled 落点），
    挡不住散文把旧口径再写一遍：`interval=0` 回退 60 分钟 / `interval=0` 视为每轮到期 /
    `intervalMin` 为 0 每轮都派发——这些句子留在 README / references / 示例数据里，测试照样全绿，
    读者照着做就是「已停项目每 60 分钟被复活一次」。本脚本补这块，写法与 tests/verify-doc-gate-claims.ps1 同款：
    钉实现事实 + 扫散文 + 自证会判红。

    五件事：
      1) 实现事实：AST 读 Get-PatrolDueSelection / Convert-BitableRowToItem 的函数体——
         调度层必须把 0/负数收进 disabled 且函数体里没有 `= 60` 回退；契约层把 <=0 归成 0；
         patrol-loop.ps1 必须走这个函数，自己不再算间隔、不再回退
      2) 文案不回流：段落级（.md）/ 行级（.json .csv .ps1 .schema）扫描，凡
         「提 interval 0 又说每轮到期/照跑」或「0 回退 60 / 当最短间隔」且无否定词、
         无「改为 / 旧实现 / 兄弟仓」标注 = 漂移
      3) 规则不空转：喂「历史旧口径原文」必须判红；喂「改正后同一句」必须绿（成对，缺一不算证据）
      4) 规则不一刀切：兄弟仓 dsh-patrol 的 `<=0 -> 60` 是「刻意保留的差异」，讲它的句子必须绿；
         表格相邻行的否定词不许外溢；`lastRun` 空 = 到期（不是停跑）不许误判
      5) 必须写的口径：入口文档 / schema / 示例数据都要写清 0 = 停跑（不能只写「0 特殊」）
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

function Get-FunctionBodyText {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw ("解析失败 {0}: {1}" -f $Path, $errors[0].Message) }
    $fn = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $fn) { return $null }
    return $fn.Extent.Text
}

# 「0 归哪一档」的散文扫描器。
#   - 段落级（.md）：空行切段；表格行各自成段（否则整张表的否定词会借给隔壁一行）。
#   - 行级（.json/.csv/.ps1/.schema）：一行一单元，避免一条否定句掩盖隔壁新长出来的谎。
# 判红的两类句子（都不需要函数名——真实的旧口径原句里也没有函数名）：
#   A) 同时提「interval 0」与「每轮到期 / 每轮都派」     → 把停跑说成每轮复活
#   B) 「回退 60」/「<=0 -> 60」/「当最短间隔」/「改写成 60」 → 本仓已废的默认间隔回退
# 白名单：显式否定（不回退 / 不做 / 不再…）、改正标记（改为 / 改成…）、
#         历史标注（旧实现 / 旧口径 / 原先…）、他仓归属（兄弟仓 / dsh-patrol / itemIsDue）。
$script:ContrastMarker = '没有|不含|不存在|不该|不得|不许|禁止|不用|不走|不接|不认|不再|绝不|不回退|不做|不是|而不是|≠|改为|改成|更正|修正为|已改|旧实现|老实现|原实现|旧口径|旧版|旧行为|旧调度器|原先|此前|兄弟仓|dsh-patrol|itemIsDue|刻意保留'
$script:EveryRoundClaim = '每轮(?:都)?到期|每轮都?(?:派|跑|唤醒|复活|照跑)|始终到期|永远到期|一律到期'
$script:SixtyFallbackClaim = '回退(?:成|到|至|为)?\s*`?60|<\s*=\s*0`?\s*(?:->|→|=>|⇒)\s*`?60|-le\s*0.{0,24}?=\s*60|item\.intervalMin\s*:\s*`?60|当\s*「?最短间隔」?|(?:改|转|设|置|写)成\s*`?60'
$script:IntervalZeroMention = '(?i)interval\s*(?:min)?\s*[=＝:：]\s*`?0(?![0-9])|intervalmin`?\s*(?:为|是|置为|设为|取)\s*`?0|间隔\s*(?:=|＝|为|是)\s*`?0'

function Get-IntervalZeroClaims {
    param(
        [string]$Text,
        [string]$Source,
        [ValidateSet('paragraph', 'line')][string]$Granularity = 'line'
    )
    $units = @()
    if ($Granularity -eq 'line') {
        $units = $Text -split "\r?\n"
    }
    else {
        foreach ($para in [regex]::Split($Text, "(?:\r?\n[ \t]*){2,}")) {
            if ($para -match '(?m)^\s*\|') { $units += ($para -split "\r?\n") } else { $units += $para }
        }
    }

    # A 类（「每轮到期」）按句子判定：一个段落里先描述旧实现、紧接又新长出一句「0 就是每轮到期」时，
    # 段落里的否定词不能替它洗白（实测：把旧口径贴到既有段落后，段落级扫描会放过它）。
    # B 类（「回退 60」）仍按段落/行：它天然需要上下文（旧实现 / 兄弟仓 / 改为）才不是谎。
    $sentences = @()
    foreach ($unit in $units) {
        if ([string]::IsNullOrWhiteSpace($unit)) { continue }
        $sentences += @([regex]::Split($unit, '(?<=[。！？；!?;])') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $hits = @()
    foreach ($s in $sentences) {
        if ($s -match $script:ContrastMarker) { continue }
        if (($s -match $script:IntervalZeroMention) -and ($s -match $script:EveryRoundClaim)) {
            $hits += [pscustomobject]@{ Source = $Source; Text = ($s -replace '\s+', ' ').Trim() }
        }
    }
    foreach ($unit in $units) {
        if ([string]::IsNullOrWhiteSpace($unit)) { continue }
        if ($unit -match $script:ContrastMarker) { continue }
        if ($unit -match $script:SixtyFallbackClaim) {
            $hits += [pscustomobject]@{ Source = $Source; Text = ($unit -replace '\s+', ' ').Trim() }
        }
    }
    return $hits
}

try {
    $schedPath = Join-Path $repoRoot 'scripts\patrol-schedule.ps1'
    $loopPath = Join-Path $repoRoot 'scripts\patrol-loop.ps1'
    $adapterPath = Join-Path $repoRoot 'scripts\BitAbleAdapter.ps1'

    # ---- 1) 实现事实：调度层把 0 收进 disabled，且函数体里没有 60 回退 ----
    $schedBody = Get-FunctionBodyText -Path $schedPath -Name 'Get-PatrolDueSelection'
    Assert-True ($null -ne $schedBody) '1) scripts/patrol-schedule.ps1 里有 Get-PatrolDueSelection'
    $schedBody = [string]$schedBody
    Assert-True ($schedBody -match '-(?:le|lt)\s*0') '1) 调度层显式比较 0（-le 0）—— 0 才有机会被判停跑'
    Assert-True ($schedBody -match 'disabled') '1) 判停跑的行收进 disabled 桶（不是静默跳过、也不是改成别的数）'
    Assert-True (-not ($schedBody -match '=\s*`?60\b')) ('1) 函数体里没有 `= 60` 回退（实得片段 {0}）' -f (($schedBody -split "\r?\n" | Where-Object { $_ -match '60' }) -join ' | '))
    Assert-True (-not ($schedBody -match ':\s*`?60\b')) '1) 函数体里没有「三元兜底成 60」'

    $loopText = [System.IO.File]::ReadAllText($loopPath, [System.Text.UTF8Encoding]::new($false))
    Assert-True ($loopText -match 'Get-PatrolDueSelection') '1) patrol-loop.ps1 走同一个 Get-PatrolDueSelection（不另写一份判定）'
    Assert-True (-not ($loopText -match '\$interval\w*\s*=\s*60')) '1) patrol-loop.ps1 自己不把间隔改写成 60'

    $normalizeBody = [string](Get-FunctionBodyText -Path $adapterPath -Name 'Convert-BitableRowToItem')
    Assert-True ($null -ne $normalizeBody -and $normalizeBody.Length -gt 0) '1) scripts/BitAbleAdapter.ps1 里有 Convert-BitableRowToItem'
    Assert-True ($normalizeBody -match '\$intervalMin\s*=\s*0\b') '1) 契约层缺列/非法一律归 0（如实翻译，不当 60）'
    Assert-True (-not ($normalizeBody -match '\$intervalMin\s*=\s*60')) ('1) 契约层不把 intervalMin 改写成 60（实得片段 {0}）' -f (($normalizeBody -split "\r?\n" | Where-Object { $_ -match '60' }) -join ' | '))

    # ---- 2) 文案不回流：扫入口文档 / references / docs / adapters / schema / 示例数据 ----
    $docSpecs = New-Object System.Collections.Generic.List[object]
    foreach ($pair in @(
            @('AGENTS.md', 'paragraph'), @('README.md', 'paragraph'), @('SKILL.md', 'paragraph'), @('CHANGELOG.md', 'paragraph'),
            @('schemas\item.schema.json', 'line'), @('scripts\sample-tasks.csv', 'line'), @('scripts\sample-tasks.json', 'line')
        )) { $docSpecs.Add([pscustomobject]@{ Path = (Join-Path $repoRoot $pair[0]); Gran = $pair[1] }) }
    foreach ($dir in @('docs', 'references')) {
        $p = Join-Path $repoRoot $dir
        if (Test-Path -LiteralPath $p) {
            foreach ($f in Get-ChildItem -LiteralPath $p -Filter *.md -File -Recurse) {
                $docSpecs.Add([pscustomobject]@{ Path = $f.FullName; Gran = 'paragraph' })
            }
        }
    }
    $adapterDir = Join-Path $repoRoot 'adapters'
    foreach ($f in Get-ChildItem -LiteralPath $adapterDir -Filter *.json -File) {
        $docSpecs.Add([pscustomobject]@{ Path = $f.FullName; Gran = 'line' })
    }
    $fixtureDir = Join-Path $repoRoot 'tests\fixtures\command'
    if (Test-Path -LiteralPath $fixtureDir) {
        foreach ($f in Get-ChildItem -LiteralPath $fixtureDir -Filter *.ps1 -File) {
            $docSpecs.Add([pscustomobject]@{ Path = $f.FullName; Gran = 'line' })
        }
    }
    $docSpecs = @($docSpecs | Where-Object { Test-Path -LiteralPath $_.Path })
    Assert-True ($docSpecs.Count -ge 15) ('2) 扫描面覆盖 {0} 份文档/描述文件/示例数据' -f $docSpecs.Count)

    $claims = @()
    $mentions = 0
    foreach ($spec in $docSpecs) {
        $text = [System.IO.File]::ReadAllText($spec.Path, [System.Text.UTF8Encoding]::new($false))
        if ($text -match '(?i)interval') { $mentions++ }
        $claims += @(Get-IntervalZeroClaims -Text $text -Source (Split-Path -Leaf $spec.Path) -Granularity $spec.Gran)
    }
    Assert-True ($mentions -ge 8) ('2) 有 {0} 份文档在讲 interval（覆盖率不是空集）' -f $mentions)
    $claimDetail = ($claims | ForEach-Object { '{0}: {1}' -f $_.Source, $_.Text }) -join ' ;; '
    Assert-True ($claims.Count -eq 0) ('2) 没有段落把 interval=0 说成「每轮到期」或「回退 60」（命中 {0} 处）' -f $claims.Count) $claimDetail

    # ---- 3) 规则不空转：历史旧口径原文必须判红 ----
    # 前三条逐字取自被修掉的真实位置（references/csv-file-adapter.md 行、scripts/sample-tasks.csv 行、
    # tests/fixtures/command/mock-jobs.ps1 的 note），都不含函数名——正是「只匹配函数名会放过真凶」的证据。
    $oldClaims = @(
        @{ Source = 'fixture/old-csv-doc'; Gran = 'line'
            Text = '| 触发间隔 | 每 30 分钟一轮；轮内再按每行 `interval` 过滤（`interval=0` 回退 60 分钟，与骨架一致） |' }
        @{ Source = 'fixture/old-sample-note'; Gran = 'line'
            Text = 'csv-A,示例项目A-紧急,P0,0,待开始,跑通 dry-run,演示 P0 且 interval=0 视为每轮到期' }
        @{ Source = 'fixture/old-json-desc'; Gran = 'line'
            Text = '"description": "演示 P0 高优先，interval=0 视为每轮到期",' }
        @{ Source = 'fixture/old-prose'; Gran = 'paragraph'
            Text = '`intervalMin` 为 `0` 的行每轮都到期，所以调度器会一直派发。' }
        @{ Source = 'fixture/old-fallback'; Gran = 'paragraph'
            Text = '间隔给 0 时按最短间隔处理，也就是回退成 60 分钟再判 due。' }
    )
    foreach ($c in $oldClaims) {
        $hits = @(Get-IntervalZeroClaims -Text $c.Text -Source $c.Source -Granularity $c.Gran)
        Assert-True ($hits.Count -ge 1) ('3) 历史旧口径原文判红：{0}（实得 {1} 处）' -f $c.Source, $hits.Count)
    }

    # ---- 3b) 改正后的同一句必须判绿 ----
    $fixedClaims = @(
        @{ Source = 'fixture/fixed-csv-doc'; Gran = 'line'
            Text = '| 触发间隔 | 每 30 分钟一轮；轮内再按每行 `interval` 过滤（`interval=0` = 停跑，不回退 60 分钟） |' }
        @{ Source = 'fixture/fixed-sample-note'; Gran = 'line'
            Text = 'csv-A,示例项目A-紧急,P0,0,待开始,跑通 dry-run,演示 P0 且 interval=0 即停跑' }
        @{ Source = 'fixture/fixed-readme'; Gran = 'paragraph'
            Text = '旧实现把 `<=0` 回退成 60 分钟，等于让已停项目每 60 分钟被唤醒一次；现实现由 `Get-PatrolDueSelection` 统一判定，**不做任何回退**。' }
        @{ Source = 'fixture/fixed-changelog'; Gran = 'paragraph'
            Text = '本轮追加主题：**`巡检间隔 = 0` 从「每轮到期」改为「停跑」**。' }
        @{ Source = 'fixture/fixed-positive'; Gran = 'paragraph'
            Text = '`intervalMin` 为 `0` = 停跑（disabled），不进 due。' }
    )
    foreach ($c in $fixedClaims) {
        $hits = @(Get-IntervalZeroClaims -Text $c.Text -Source $c.Source -Granularity $c.Gran)
        Assert-True ($hits.Count -eq 0) ('3) 改正后的文案判绿：{0}（实得 {1} 处）' -f $c.Source, $hits.Count) (($hits | ForEach-Object { $_.Text }) -join ' ;; ')
    }

    # ---- 4) 不一刀切：他仓归属 / 表格相邻行 / lastRun 语义 ----
    $sibling = '> 与兄弟仓 `dsh-patrol` 的差异是**刻意保留**的：它的 `src/mapping.ts::itemIsDue` 仍是 `intervalMin <= 0 -> 60`（把 `0` 当「最短间隔」）。'
    Assert-True (@(Get-IntervalZeroClaims -Text $sibling -Source 'fixture/sibling').Count -eq 0) `
        '4) 讲兄弟仓 dsh-patrol 的 `<=0 -> 60` 不误判（规则只咬本仓口径）'
    $notParked = '`intervalMin=90` 刚跑过不进 due（但也不是 disabled/停跑）；`intervalMin=1` 且 `lastRun` 空必须进。'
    Assert-True (@(Get-IntervalZeroClaims -Text $notParked -Source 'fixture/not-parked').Count -eq 0) `
        '4) 「未到期 ≠ 停跑」的句子不误判'
    $lastRunNote = '> 注意 `lastRun` 的「空」不等于停跑：`lastRun` 空 = 没跑过，仍然到期。停跑只看 `intervalMin`。'
    Assert-True (@(Get-IntervalZeroClaims -Text $lastRunNote -Source 'fixture/lastrun').Count -eq 0) `
        '4) 「lastRun 空 = 到期」不误判成停跑口径'
    # 相邻表格行不许借否定词：上一行说「停跑」，下一行新长出一个 60 回退仍要判红
    $sneaky = @'
| `0` | **停跑（disabled）**：只计数，永不进入 due |
| `intervalMin` = `0` | 回退 60 分钟后照常派发 |
'@
    Assert-True (@(Get-IntervalZeroClaims -Text $sneaky -Source 'fixture/table' -Granularity 'paragraph').Count -eq 1) `
        '4) 表格里相邻行的否定词不外溢（仍判红 1 处）'
    # 同一段落里先讲旧实现、紧接新长出一句「0 就是每轮到期」也必须判红（句子级，否定词不外溢）
    $samePara = '旧实现把 `<=0` 回退成 60 分钟，早该废。本轮实测：按表里 `interval=0` 的行每轮都到期，照常派发。'
    Assert-True (@(Get-IntervalZeroClaims -Text $samePara -Source 'fixture/same-para' -Granularity 'paragraph').Count -eq 1) `
        '4) 旧实现描述不许给同段落里新出现的「每轮到期」洗白（仍判红 1 处）'

    # ---- 5) 必须写的口径：入口文档 / schema / 示例数据都要写清 0 = 停跑 ----
    $mustWrite = @(
        @{ Path = 'README.md'; Patterns = @('停跑', 'disabled') }
        @{ Path = 'AGENTS.md'; Patterns = @('停跑') }
        @{ Path = 'references\adding-a-provider.md'; Patterns = @('停跑') }
        @{ Path = 'references\adapter-spec.md'; Patterns = @('停跑') }
        @{ Path = 'docs\tencent-docs-adapter.md'; Patterns = @('停跑') }
        @{ Path = 'SKILL.md'; Patterns = @('disabled', 'parked') }
        @{ Path = 'schemas\item.schema.json'; Patterns = @('0 = 停跑') }
        @{ Path = 'scripts\sample-tasks.csv'; Patterns = @('停跑') }
        @{ Path = 'scripts\sample-tasks.json'; Patterns = @('停跑') }
    )
    foreach ($m in $mustWrite) {
        $p = Join-Path $repoRoot $m.Path
        if (-not (Test-Path -LiteralPath $p)) { Assert-True $false ('5) {0} 存在' -f $m.Path) '文件不存在'; continue }
        $t = [System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($false))
        $missing = @($m.Patterns | Where-Object { $t -notmatch [regex]::Escape($_) })
        Assert-True ($missing.Count -eq 0) ('5) {0} 写清了 0 = 停跑（缺 {1}）' -f $m.Path, ($missing -join ','))
    }
} catch {
    $fail++
    Write-Host ('FAIL exception: {0}' -f $_.Exception.Message)
}

Write-Host ('summary pass={0} fail={1}' -f $pass, $fail)
if ($fail -gt 0) { Write-Host 'RESULT: FAIL'; exit 1 }
Write-Host 'RESULT: PASS'
exit 0
