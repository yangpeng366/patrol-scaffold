#requires -Version 7
<#
.SYNOPSIS
  patrol-schedule.ps1 - due-list 判定（第 2 层 Scheduler 的纯逻辑，不派发、不写盘）。
.DESCRIPTION
  把「这一行这一轮该不该跑」从 patrol-loop.ps1 拆到这里，是为了让
  tests/verify-disabled-scheduling.ps1 能 dot-source 真函数，并通过对副本做文本变异
  自证闸门本身不会说谎——不需要真跑一整轮调度。

  生产口径（表数据约定优先，见 README「巡检间隔」/ CHANGELOG）：
    intervalMin > 0  且  lastRun 为空 / 解析不出 / 已超间隔   -> due（派发）
    intervalMin > 0  且  lastRun 未超间隔                     -> 未到期（不派发，也不是停跑）
    intervalMin 0 / 负数 / 空串 / null / 缺列                 -> disabled（停跑，只计数不派发）

  「0 = 停跑」是刻意的：方向表里 0 值行普遍写「停跑 / 停用 / 只读留档」。老实现把
  <=0 回退成 60 分钟，等于让已停项目每 60 分钟被复活一次。
  注意 lastRun 为空是「没跑过」，仍然到期；「空 = 停跑」只针对 intervalMin。

  与 dsh-patrol 的差异（刻意保留）：兄弟仓 src/mapping.ts::itemIsDue 仍是
  `item.intervalMin > 0 ? item.intervalMin : 60`，即把 0 当「最短间隔」。本仓不改兄弟仓；
  若要把本仓的表接进 dsh 的 auto 模式，**必须先做映射**（停跑行换标记，或改 itemIsDue），
  否则已停行会被 dsh 每 60 分钟唤醒一次。

.NOTES
  本文件只放纯函数：无 I/O、无 $env、无全局状态，可反复 dot-source。
#>

<#
    取字段：同时接受 PSCustomObject 与 hashtable / ordered dictionary；
    属性不存在时返回 $null（调用方据此区分「缺列」与「0」）。
#>
function Get-PatrolItemField {
    param($Item, [string]$Name)
    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $prop = $Item.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

<#
    把行里的 intervalMin 翻成分钟数；返回 $null 表示「没给 / 给的不是数」。
    与解析层同口径：小数向下取整（45.7 -> 45）；负数原样返回（由调度层判停跑）。
#>
function ConvertTo-PatrolInterval {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ($text -eq '') { return $null }
        $num = 0.0
        $ok = [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)
        if (-not $ok) { return $null }
        return [int][math]::Floor($num)
    }
    try { return [int][math]::Floor([double]$Value) } catch { return $null }
}

<#
    一次算出本轮的 due / disabled。
      -Items : 归一后的 item 列表（也接受原始行，缺 intervalMin 即停跑）
      -Now   : 本轮开始时间（测试可注入固定时刻）
    返回 [pscustomobject]@{ Due = @(...); Disabled = @(...) }，两者互斥，其余即「未到期」。
#>
function Get-PatrolDueSelection {
    param([object[]]$Items, [datetime]$Now = (Get-Date))

    $due = New-Object System.Collections.Generic.List[object]
    $disabled = New-Object System.Collections.Generic.List[object]

    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }

        # 停跑判定：空 / 缺列 / 0 / 负数 一律不进入调度（绝不回退默认间隔）
        $interval = ConvertTo-PatrolInterval -Value (Get-PatrolItemField -Item $it -Name 'intervalMin')
        if (($null -eq $interval) -or ($interval -le 0)) { $disabled.Add($it); continue }

        # 到期判定：lastRun 空或解析不出 = 没跑过 -> 到期；否则看是否已超间隔
        $last = $null
        $lastRaw = Get-PatrolItemField -Item $it -Name 'lastRun'
        if ($null -ne $lastRaw) {
            $lastText = ([string]$lastRaw).Trim()
            if ($lastText -ne '') {
                try { $last = [datetime]$lastText } catch { $last = $null }
            }
        }
        if ($null -eq $last) { $due.Add($it); continue }
        if (($Now - $last).TotalMinutes -ge $interval) { $due.Add($it) }
    }

    return [pscustomobject]@{
        Due      = @($due.ToArray())
        Disabled = @($disabled.ToArray())
    }
}
