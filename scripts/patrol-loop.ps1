#requires -Version 7
<#
.SYNOPSIS
  patrol-loop.ps1 - 最小可跑巡检 round 调度器（provider=local-json, worker=dry-run）。
.DESCRIPTION
  拷贝即用的参考实现，演示蓝皮书七层里的第 2/3/6 层：
  due-list（per-row interval+优先级）-> worker 池（Start-Job 并发上限）-> 回写 -> digest。
  worker 默认 dry-run（不依赖 codex/凭据）；真实模式钩子见 worker ScriptBlock 注释。
  运行态写 state/patrol-state.json，源只读。
.NOTES
  实测: pwsh -File patrol-loop.ps1 -TasksFile sample-tasks.json -Once -DryRun
#>
param(
    [string]$TasksFile = (Join-Path $PSScriptRoot 'sample-tasks.json'),
    [string]$BitableConfigPath = '',  # required when PATROL_ADAPTER=bitable,
    [int]$MaxChildren = 2,
    [int]$RoundTimeoutSec = 120,
    [switch]$DryRun,
    [switch]$Once,
    [string]$JevShadowConfigPath = (Join-Path $PSScriptRoot '..\jev-shadow-hooks\patrol-shadow-config.json'),
    [string]$JevShadowOutputDir = (Join-Path $PSScriptRoot 'downloads\jev-shadow'),
    [string]$StateFile = (Join-Path $PSScriptRoot '..\state\patrol-state.json')
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
. (Join-Path $PSScriptRoot 'patrol-provider.ps1')
. (Join-Path $PSScriptRoot 'patrol-state.ps1')
. (Join-Path $PSScriptRoot 'patrol-schedule.ps1')
$AdapterName = if($env:PATROL_ADAPTER){ $env:PATROL_ADAPTER } else { 'local-json' }
# Jev 影子层是可选组件（本地业务扩展），不在本仓分发；缺它则本仓仍可独立运行。
$JevShadowLib = Join-Path $PSScriptRoot 'JevShadow.ps1'
$JevShadowAvailable = Test-Path -LiteralPath $JevShadowLib
if($JevShadowAvailable){ . $JevShadowLib }
$JevDecisionEndpoint = Join-Path $PSScriptRoot 'Invoke-ItemJevDecision.ps1'
$JevDecisionAvailable = Test-Path -LiteralPath $JevDecisionEndpoint
# 装配源适配器：换 provider = 换 adapters/<name>.adapter.json，本文件不改。
$Provider = Import-PatrolProvider -Provider $AdapterName -Values @{ tasksFile = $TasksFile; configPath = $BitableConfigPath }
$JevShadowConfig = @{ enabled = $false }
if($JevShadowConfigPath -and (Test-Path -LiteralPath $JevShadowConfigPath)){ $JevShadowConfig = Get-Content -LiteralPath $JevShadowConfigPath -Raw | ConvertFrom-Json }
$JevDecisionConfigPath = if($env:JEV_DECISION_CONFIG_PATH){ $env:JEV_DECISION_CONFIG_PATH } else { Join-Path $PSScriptRoot '..\\config\\jev-decision.json' }
$JevDecisionConfig = @{ decision = @{ enabled = $false; thresholds = @{ low = 0.30; high = 0.70 } } }
if($JevDecisionConfigPath -and (Test-Path -LiteralPath $JevDecisionConfigPath)){ try { $JevDecisionConfig = Get-Content -LiteralPath $JevDecisionConfigPath -Raw | ConvertFrom-Json } catch {} }

$OutDir = Join-Path $PSScriptRoot 'downloads'
$MemDir = Join-Path $PSScriptRoot 'memory'
foreach ($d in @($OutDir, $MemDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

# 第2层不变量: 全局互斥（单实例）。演示用，失败不阻塞。
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\patrol-scaffold-demo')
    if (-not $mutex.WaitOne(2000)) { Write-Host '[skip] another instance running'; exit 0 }
} catch { Write-Host "[warn] mutex unavailable, continuing: $($_.Exception.Message)"; $mutex = $null }

try {
    $roundStart = Get-Date
    $stamp = $roundStart.ToString('yyyyMMdd-HHmmss')
    $items = @(Get-PatrolProviderItems -Provider $Provider)
    $state = Read-PatrolState -Path $StateFile
    $items = @(Merge-PatrolState -Items $items -State $state)
    $PriorityOrder = @{ 'P0' = 0; 'P1' = 1; 'P2' = 2 }
    $now = Get-Date

    # ---- due-list: per-row interval + 优先级 ----
    # 生产口径：intervalMin > 0 且 lastRun 空/超间隔才到期；0 / 空 / 缺列 / 负数 = 停跑（disabled）。
    # 这里**不再**把 <=0 回退成 60——那会让已停项目每 60 分钟被复活一次（见 patrol-schedule.ps1）。
    $selection = Get-PatrolDueSelection -Items $items -Now $now
    $dueArr = @($selection.Due | Sort-Object { $p = $_.priority; if ($PriorityOrder.ContainsKey($p)) { $PriorityOrder[$p] } else { 99 } })
    $disabledArr = @($selection.Disabled)
    Write-Host "[round] due=$($dueArr.Count)/$($items.Count) disabled=$($disabledArr.Count) maxChildren=$MaxChildren dryRun=$DryRun"

    # ---- worker 池（第3层）----
    $jobs = New-Object System.Collections.Generic.List[object]
    $idx = 0; $completed = 0; $failed = 0
    while (($idx -lt $dueArr.Count) -or ($jobs.Count -gt 0)) {
        if (((Get-Date) - $roundStart).TotalSeconds -gt $RoundTimeoutSec) { Write-Host '[warn] round timeout'; break }
        while (($jobs.Count -lt $MaxChildren) -and ($idx -lt $dueArr.Count)) {
            $it = $dueArr[$idx]; $idx++
            $job = Start-Job -Name "patrol-$($it.id)-$stamp" -ScriptBlock {
                param($Id, $Title, $RepoPath, $Description, $NextStep, $DryRun)
                $start = Get-Date
                Start-Sleep -Milliseconds 150   # 模拟一段有界工作
                if ($DryRun) {
                    return [pscustomobject]@{
                        id = $Id
                        status = 'completed'
                        action = ''
                        currentStage = '完成(dry-run)'
                        achievement = "dry-run: 模拟完成 [$Title] 的一轮有界工作（仓库 $RepoPath；下一步: $NextStep）"
                        threadId = $null
                        durationSec = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
                    }
                }
                # ===== 真实模式钩子（第3层 worker）=====
                # $prompt = "项目:$Title`n仓库:$RepoPath`n描述:$Description`n下一步:$NextStep`n时间自控:超时主动拆分到下轮"
                # $tid = $it.threadId
                # if ($tid) { & codex exec --resume $tid "$prompt" } else { & codex exec "$prompt" }
                # 把返回的 thread id 填到 threadId 回写；连续失败 N 次重置见 references/patrol-blueprint.md
                throw 'real worker not implemented; pass -DryRun, or implement the codex exec hook here'
            } -ArgumentList $it.id, $it.title, $it.repoPath, $it.description, $it.nextStep, $DryRun
            $jobs.Add($job) | Out-Null
        }
        if ($jobs.Count -gt 0) {
            Start-Sleep -Milliseconds 300
            $still = New-Object System.Collections.Generic.List[object]
            foreach ($j in $jobs) {
                if ($j.State -in @('Completed', 'Failed', 'Stopped')) {
                    $res = $null
                    try { $res = Receive-Job -Job $j -Keep } catch { Write-Host "[worker] recv err $($j.Name): $($_.Exception.Message)" }
                    if ($j.State -eq 'Completed' -and $res) {
                        $target = $items | Where-Object { $_.id -eq $res.id } | Select-Object -First 1
                        if ($target) {
                            $target.currentStage = $res.currentStage
                            $target.achievement = $res.achievement
                            if ($res.threadId) { $target.threadId = $res.threadId }
                            $target.lastRun = (Get-Date).ToString('o')
                        }
                        if($JevShadowAvailable -and (Get-JevShadowEnabled -Config $JevShadowConfig)){
                            $shadowCtx = New-PatrolItemJevShadowContext -Item $target
                            $shadowDecision = Invoke-PatrolItemJevShadow -Context $shadowCtx -Config $JevShadowConfig
                            $shadowArtifact = New-PatrolJevShadowArtifact -Context $shadowCtx -Decision $shadowDecision -Enabled $true
                            $shadowMode = if($DryRun){ "dry-run" } else { "real" }
                            $shadowArtifact = Complete-PatrolJevShadowArtifact -Artifact $shadowArtifact -WorkerResult $res -WorkerMode $shadowMode
                            Write-PatrolJevShadow -Artifact $shadowArtifact -OutputDir $JevShadowOutputDir | Out-Null
                        }
                        Write-Host ("[worker] done {0} dur={1}s -> {2}" -f $res.id, $res.durationSec, $res.achievement)
                        $completed++
                        $decisionItemJson = [ordered]@{ id = $target.id; title = $target.title; repoPath = $target.repoPath; description = $target.description; nextStep = $target.nextStep; priority = $target.priority; intervalMin = $target.intervalMin; threadId = $target.threadId; fake = $target.fake }
                        $decisionItemPath = Join-Path $env:TEMP ("dec-item-" + [guid]::NewGuid().ToString("N") + ".json")
                        [System.IO.File]::WriteAllText($decisionItemPath, ($decisionItemJson | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
                        $decisionLogPath = Join-Path $env:TEMP ("dec-item-log-" + [guid]::NewGuid().ToString("N") + ".json")
                        try {
                            if(-not $JevDecisionAvailable){ throw 'Jev 决策端点未安装（可选组件，跳过）' }
                            $null = & pwsh -NoProfile -File $JevDecisionEndpoint -ItemJsonPath $decisionItemPath -JevShadowConfigPath $JevShadowConfigPath -JevDecisionConfigPath $JevDecisionConfigPath -DecisionLogPath $decisionLogPath 2>&1
                            if (Test-Path -LiteralPath $decisionLogPath) { try { $decisionResult = Get-Content -LiteralPath $decisionLogPath -Raw | ConvertFrom-Json } catch { $decisionResult = $null } } else { $decisionResult = $null }
                            if ($decisionResult.decision.action -eq 'HUMAN_REVIEW' -and $JevDecisionConfig.decision.enabled) {
                                Write-Host ("[decision] HUMAN_REVIEW on item " + $decisionResult.item_id + " reason=" + $decisionResult.decision.reason)
                                $target.currentStage = "HUMAN_REVIEW pending"
                                continue
                            }
                        } catch {
                            Write-Host ("[decision] endpoint failed, continuing: " + $_.Exception.Message)
                        } finally {
                            Remove-Item -LiteralPath $decisionItemPath -ErrorAction SilentlyContinue
                        }
                    } else {
                        Write-Host ("[worker] FAIL {0} state={1}" -f $j.Name, $j.State); $failed++
                    }
                    Remove-Job -Job $j -Force
                } else { $still.Add($j) | Out-Null }
            }
            $jobs = $still
        }
    }

    # ---- 第4层 sync-back: 运行态外置（源只读） ----
    Save-PatrolState -Path $StateFile -Items $items

    # ---- 第6层 output: digest json + md + memory 追加 ----
    $digest = [pscustomobject]@{
        stamp = $stamp; method = $AdapterName; dryRun = [bool]$DryRun
        totalItems = $items.Count; dueCount = $dueArr.Count
        completed = $completed; failed = $failed
        items = @($items | Select-Object id, title, priority, intervalMin, currentStage, lastRun, achievement)
    }
    $jpath = Join-Path $OutDir "patrol-$stamp.json"
    [System.IO.File]::WriteAllText($jpath, ($digest | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    $md = "## 巡检 ($AdapterName$(if($DryRun){' dry-run'})) $stamp`n- 总计: $($items.Count) | 到期: $($dueArr.Count) | 完成: $completed | 失败: $failed`n"
    foreach ($it in $items) { $md += "- [$($it.priority)] $($it.title): $($it.currentStage)`n" }
    $mpath = Join-Path $OutDir "patrol-$stamp.md"
    [System.IO.File]::WriteAllText($mpath, $md, [System.Text.UTF8Encoding]::new($false))
    Add-Content -LiteralPath (Join-Path $MemDir 'patrol-memory.md') -Value $md -Encoding UTF8
    Write-Host "[done] digest: $jpath"
    Write-Host "[done] md:     $mpath"
}
finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
}
