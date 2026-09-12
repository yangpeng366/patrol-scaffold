#requires -Version 7
<#
.SYNOPSIS
  patrol-loop.ps1 - 最小可跑巡检 round 调度器（provider=local-json, worker=dry-run）。
.DESCRIPTION
  拷贝即用的参考实现，演示蓝皮书七层里的第 2/3/6 层：
  due-list（per-row interval+优先级）-> worker 池（Start-Job 并发上限）-> 回写 -> digest。
  worker 默认 dry-run（不依赖 codex/凭据）；真实模式钩子见 worker ScriptBlock 注释。
.NOTES
  实测: pwsh -File patrol-loop.ps1 -TasksFile sample-tasks.json -Once -DryRun
#>
param(
    [string]$TasksFile = (Join-Path $PSScriptRoot 'sample-tasks.json'),
    [int]$MaxChildren = 2,
    [int]$RoundTimeoutSec = 120,
    [switch]$DryRun,
    [switch]$Once
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
. (Join-Path $PSScriptRoot 'local-json-adapter.ps1')

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
    $items = @(Get-PatrolItems -TasksFile $TasksFile)
    $PriorityOrder = @{ 'P0' = 0; 'P1' = 1; 'P2' = 2 }
    $DefaultIntervalMin = 60
    $now = Get-Date

    # ---- due-list: per-row interval + 优先级 ----
    $due = New-Object System.Collections.Generic.List[object]
    foreach ($it in $items) {
        $interval = [int]$it.intervalMin
        if ($interval -le 0) { $interval = $DefaultIntervalMin }   # 0/空 -> 回退 60（同在用系统）
        $last = [datetime]::MinValue
        if ($it.lastRun) { try { $last = [datetime]$it.lastRun } catch { $last = [datetime]::MinValue } }
        if (($now - $last).TotalMinutes -ge $interval) { $due.Add($it) }
    }
    $dueArr = $due | Sort-Object { $p = $_.priority; if ($PriorityOrder.ContainsKey($p)) { $PriorityOrder[$p] } else { 99 } }
    Write-Host "[round] due=$($dueArr.Count)/$($items.Count) maxChildren=$MaxChildren dryRun=$DryRun"

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
                        Write-Host ("[worker] done {0} dur={1}s -> {2}" -f $res.id, $res.durationSec, $res.achievement)
                        $completed++
                    } else {
                        Write-Host ("[worker] FAIL {0} state={1}" -f $j.Name, $j.State); $failed++
                    }
                    Remove-Job -Job $j -Force
                } else { $still.Add($j) | Out-Null }
            }
            $jobs = $still
        }
    }

    # ---- 第4层 sync-back: 落盘 ----
    Save-PatrolItems -TasksFile $TasksFile -Items $items

    # ---- 第6层 output: digest json + md + memory 追加 ----
    $digest = [pscustomobject]@{
        stamp = $stamp; method = 'local-json'; dryRun = [bool]$DryRun
        totalItems = $items.Count; dueCount = $dueArr.Count
        completed = $completed; failed = $failed
        items = @($items | Select-Object id, title, priority, intervalMin, currentStage, lastRun, achievement)
    }
    $jpath = Join-Path $OutDir "patrol-$stamp.json"
    [System.IO.File]::WriteAllText($jpath, ($digest | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    $md = "## 巡检 (local-json dry-run) $stamp`n- 总计: $($items.Count) | 到期: $($dueArr.Count) | 完成: $completed | 失败: $failed`n"
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