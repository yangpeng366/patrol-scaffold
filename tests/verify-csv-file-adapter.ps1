#requires -Version 7
<#
.SYNOPSIS
  verify-csv-file-adapter.ps1 — provider=csv-file 的离线自测（全部在 %TEMP% 沙箱里造数据）。

.DESCRIPTION
  直接 dot-source scripts/csv-file-adapter.ps1，不联网、不装依赖、不碰仓内样本：
    1) 正常读取：行数、id/title/priority/interval 映射、前后空格、短行、空行/纯空白行、CRLF/LF 混排
    2) 带引号的逗号与换行：字段不串行、不产生幽灵行
    3) 列映射可配置（中文表头）
    4) 缺必填列：另一个 pwsh 进程非零退出，且报错文本点名缺哪列
    5) write-back：只改目标行、其余行字节不变、行序不变、无 BOM、幂等
    6) write-back 契约入口 Save-PatrolItems（currentStage/nextStep/achievement -> status/action/note）
    7) 异常：目标 id 不存在、id 重复 -> 明确报错

.PARAMETER KeepTemp
  保留沙箱目录以便人工复核（默认跑完清理）。

.EXAMPLE
  pwsh -NoProfile -File tests/verify-csv-file-adapter.ps1
#>
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$adapterPath = Join-Path $root 'scripts\csv-file-adapter.ps1'
if (-not (Test-Path -LiteralPath $adapterPath)) { throw "adapter not found: $adapterPath" }
. $adapterPath

$pass = 0
$fail = 0

function Assert-True {
    param([bool]$Condition, [string]$Label, [string]$Detail)
    if ($Condition) {
        Write-Host "PASS $Label"
        $script:pass++
    }
    else {
        Write-Host "FAIL $Label"
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "     $Detail" }
        $script:fail++
    }
}

function Write-Fixture {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Read-Fixture {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Test-HasBom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

$sandbox = Join-Path $env:TEMP ('csv-file-adapter-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
Write-Host "sandbox: $sandbox"

try {
    # ---------------------------------------------------------------------
    # 1) 正常读取：前后空格、短行、空行/纯空白行、CRLF/LF 混排
    # ---------------------------------------------------------------------
    $basic = Join-Path $sandbox 'basic.csv'
    $basicText = "id, title ,priority,interval,status,action,note`r`n" +
                 "csv-A, 项目A ,P0,30,进行中,跑通 dry-run,备注一`n" +
                 "csv-B,项目B,P1,60,待开始,等下一轮,`r`n" +
                 "`n" +
                 "   `r`n" +
                 "csv-C,项目C,P2,0"
    Write-Fixture -Path $basic -Text $basicText

    $items = @(Get-PatrolItems -CsvPath $basic)
    Assert-True ($items.Count -eq 3) 'basic: 3 data rows (blank + whitespace-only lines skipped)' "got $($items.Count)"
    Assert-True (($items | ForEach-Object { $_.id }) -join ',' -eq 'csv-A,csv-B,csv-C') 'basic: ids in file order' (($items | ForEach-Object { $_.id }) -join ',')
    Assert-True ($items[0].title -eq '项目A') 'basic: header/value outer spaces trimmed' "title=[$($items[0].title)]"
    Assert-True ($items[0].priority -eq 'P0') 'basic: priority mapped' "priority=[$($items[0].priority)]"
    Assert-True ($items[0].intervalMin -eq 30) 'basic: interval 30 -> intervalMin' "intervalMin=[$($items[0].intervalMin)]"
    Assert-True ($items[1].intervalMin -eq 60) 'basic: flexend column without newline still parsed' "intervalMin=[$($items[1].intervalMin)]"
    Assert-True ($items[1].description -eq '') 'basic: empty trailing cell -> empty note' "note=[$($items[1].description)]"
    Assert-True ($items[0].currentStage -eq '进行中') 'basic: status -> currentStage' "status=[$($items[0].currentStage)]"
    Assert-True ($items[1].nextStep -eq '等下一轮') 'basic: action -> nextStep' "action=[$($items[1].nextStep)]"
    Assert-True ($items[2].intervalMin -eq 0) 'basic: short row without interval -> 0' "intervalMin=[$($items[2].intervalMin)]"
    Assert-True ($items[2].currentStage -eq '') 'basic: short row without status -> empty' "status=[$($items[2].currentStage)]"
    Assert-True ((Resolve-ItemName -Item $items[0]) -eq '项目A') 'resolve-name returns the row title'

    # ---------------------------------------------------------------------
    # 2) 引号内的逗号与换行：不串行、不产生幽灵行
    # ---------------------------------------------------------------------
    $quoted = Join-Path $sandbox 'quoted.csv'
    $quotedText = "id,title,priority,interval,note`r`n" +
                  "csv-Q1,`"标题, 带逗号`",P0,15,`"备注里同时有逗号, 和 `"`"引号`"`"`"`r`n" +
                  "csv-Q2,`"多行标题`n第二行`",P1,60,`"多行备注`r`n第二段`"`r`n" +
                  "csv-Q3,普通,P2,0,`r`n"
    Write-Fixture -Path $quoted -Text $quotedText

    $q = @(Get-PatrolItems -CsvPath $quoted)
    Assert-True ($q.Count -eq 3) 'quoted: embedded newline does not create a phantom row' "got $($q.Count)"
    Assert-True ($q[0].title -eq '标题, 带逗号') 'quoted: embedded comma stays in one cell' "title=[$($q[0].title)]"
    Assert-True ($q[0].description -eq '备注里同时有逗号, 和 "引号"') 'quoted: doubled quotes decoded' "note=[$($q[0].description)]"
    Assert-True ($q[1].title.Contains('多行标题') -and $q[1].title.Contains('第二行')) 'quoted: multi-line title kept whole' "title=[$($q[1].title)]"
    Assert-True ($q[1].description.Contains('多行备注') -and $q[1].description.Contains('第二段')) 'quoted: multi-line note kept whole' "note=[$($q[1].description)]"
    Assert-True ($q[2].id -eq 'csv-Q3') 'quoted: following row still aligned' "id=[$($q[2].id)]"

    # ---------------------------------------------------------------------
    # 3) 列映射可配置（中文表头）
    # ---------------------------------------------------------------------
    $mapped = Join-Path $sandbox 'mapped.csv'
    Write-Fixture -Path $mapped -Text ("编号,标题,优先级,间隔,状态,动作,备注`r`n" + "m-1,映射行一,P0,15,进行中,下一步动作,映射备注`r`n")
    $cmap = 'id=编号;title=标题;priority=优先级;interval=间隔;status=状态;action=动作;note=备注'
    $m = @(Get-PatrolItems -CsvPath $mapped -ColumnMap $cmap)
    Assert-True ($m.Count -eq 1) 'columnMap: custom headers read' "got $($m.Count)"
    Assert-True ($m[0].id -eq 'm-1' -and $m[0].title -eq '映射行一' -and $m[0].intervalMin -eq 15) 'columnMap: id/title/interval mapped' "id=[$($m[0].id)] title=[$($m[0].title)] interval=[$($m[0].intervalMin)]"
    Assert-True ($m[0].currentStage -eq '进行中' -and $m[0].nextStep -eq '下一步动作' -and $m[0].description -eq '映射备注') 'columnMap: status/action/note mapped' "status=[$($m[0].currentStage)] action=[$($m[0].nextStep)] note=[$($m[0].description)]"

    # ---------------------------------------------------------------------
    # 4) 缺必填列 -> 独立进程非零退出，且文本点名缺列
    # ---------------------------------------------------------------------
    $missing = Join-Path $sandbox 'missing.csv'
    Write-Fixture -Path $missing -Text ("id,title,interval`r`n" + "csv-M1,缺列行,30`r`n")
    $runner = Join-Path $sandbox 'run-missing.ps1'
    $runnerBody = @(
        "`$ErrorActionPreference = 'Stop'"
        ". '$adapterPath'"
        "`$rows = @(Get-PatrolItems -CsvPath '$missing')"
        "'items=' + `$rows.Count"
    ) -join [Environment]::NewLine
    Write-Fixture -Path $runner -Text $runnerBody
    $childOut = (& pwsh -NoProfile -File $runner 2>&1 | Out-String)
    $childCode = $LASTEXITCODE
    Assert-True ($childCode -ne 0) 'missing column: child pwsh exits non-zero' "exit=$childCode out=$($childOut.Trim())"
    Assert-True ($childOut -match '缺必填列') 'missing column: error text says a required column is missing' $childOut.Trim()
    Assert-True ($childOut -match 'priority') 'missing column: error text names the missing column (priority)' $childOut.Trim()

    # ---------------------------------------------------------------------
    # 5) write-back：只改目标行、其余行字节不变、无 BOM、幂等
    # ---------------------------------------------------------------------
    $wb = Join-Path $sandbox 'writeback.csv'
    $wbText = "id,title,priority,interval,status,action,note`r`n" +
              "csv-W1,`"标题, 一`",P0,30,进行中,推进,`"备注一`"`r`n" +
              "csv-W2,标题二,P1,60,待开始,等待,`"备注`"`"引号`"`"`"`r`n" +
              "csv-W3,标题三,P2,0,,`r`n"
    Write-Fixture -Path $wb -Text $wbText
    $before = Read-Fixture -Path $wb
    $beforeLines = $before -split "`r`n"

    $changed = Set-PatrolCsvRowFields -CsvPath $wb -Id 'csv-W2' -Fields @{ status = '已完成' }
    $after = Read-Fixture -Path $wb
    $afterLines = $after -split "`r`n"

    Assert-True ($changed -eq 1) 'write-back: one row reported updated' "changed=$changed"
    Assert-True ($after -cne $before) 'write-back: file actually changed'
    Assert-True ($afterLines.Count -eq $beforeLines.Count) 'write-back: line count unchanged' "before=$($beforeLines.Count) after=$($afterLines.Count)"
    $diffIdx = @()
    for ($i = 0; $i -lt $beforeLines.Count; $i++) { if ($afterLines[$i] -cne $beforeLines[$i]) { $diffIdx += $i } }
    Assert-True (($diffIdx -join ',') -eq '2') 'write-back: only the target record line changed (byte-identical elsewhere)' "changed lines: $($diffIdx -join ',')"
    Assert-True ($afterLines[2] -match '已完成') 'write-back: new status landed on the target row'

    $wbRows = @(Import-Csv -LiteralPath $wb -Encoding utf8)
    Assert-True ($wbRows.Count -eq 3) 'write-back: record count unchanged' "got $($wbRows.Count)"
    Assert-True (($wbRows | ForEach-Object { $_.id }) -join ',' -eq 'csv-W1,csv-W2,csv-W3') 'write-back: row order preserved' (($wbRows | ForEach-Object { $_.id }) -join ',')
    Assert-True ($wbRows[1].status -eq '已完成' -and $wbRows[1].action -eq '等待') 'write-back: only the requested column changed' "status=[$($wbRows[1].status)] action=[$($wbRows[1].action)]"
    Assert-True ($wbRows[1].note -eq '备注"引号"') 'write-back: quoted/escaped neighbours survive' "note=[$($wbRows[1].note)]"
    Assert-True ($wbRows[0].title -eq '标题, 一') 'write-back: other rows keep their quoted commas' "title=[$($wbRows[0].title)]"
    Assert-True (-not (Test-HasBom -Path $wb)) 'write-back: output has no BOM'

    $reRead = @(Get-PatrolItems -CsvPath $wb)
    Assert-True ($reRead.Count -eq 3 -and $reRead[1].currentStage -eq '已完成') 'write-back: written file re-reads consistently' "count=$($reRead.Count)"

    $changed2 = Set-PatrolCsvRowFields -CsvPath $wb -Id 'csv-W2' -Fields @{ status = '已完成' }
    $after2 = Read-Fixture -Path $wb
    Assert-True ($changed2 -eq 0) 'write-back: same value -> reported 0 changes' "changed=$changed2"
    Assert-True ($after2 -ceq $after) 'write-back: idempotent (bytes unchanged on no-op)'

    # ---------------------------------------------------------------------
    # 6) write-back 契约入口 Save-PatrolItems
    # ---------------------------------------------------------------------
    $wb2 = Join-Path $sandbox 'writeback-contract.csv'
    Copy-Item -LiteralPath $wb -Destination $wb2
    $before2 = (Read-Fixture -Path $wb2) -split "`r`n"
    $rows = @(Get-PatrolItems -CsvPath $wb2)
    $target = $rows | Where-Object { $_.id -eq 'csv-W1' }
    $target.currentStage = '完成(dry-run)'
    $target.nextStep = '交付'
    $target | Add-Member -NotePropertyName achievement -NotePropertyValue 'dry-run: 模拟完成' -Force
    $saved = Save-PatrolItems -CsvPath $wb2 -Items @($target)
    $after2Lines = (Read-Fixture -Path $wb2) -split "`r`n"
    $diffIdx2 = @()
    for ($i = 0; $i -lt $before2.Count; $i++) { if ($after2Lines[$i] -cne $before2[$i]) { $diffIdx2 += $i } }
    Assert-True ($saved -eq 1) 'Save-PatrolItems: one row updated' "saved=$saved"
    Assert-True (($diffIdx2 -join ',') -eq '1') 'Save-PatrolItems: only the target row line changed' "changed lines: $($diffIdx2 -join ',')"
    $cRows = @(Import-Csv -LiteralPath $wb2 -Encoding utf8)
    Assert-True ($cRows[0].status -eq '完成(dry-run)' -and $cRows[0].action -eq '交付' -and $cRows[0].note -eq 'dry-run: 模拟完成') 'Save-PatrolItems: currentStage/nextStep/achievement -> status/action/note' "status=[$($cRows[0].status)] action=[$($cRows[0].action)] note=[$($cRows[0].note)]"

    # ---------------------------------------------------------------------
    # 7) 异常：目标 id 不存在、id 重复
    # ---------------------------------------------------------------------
    $errMissingId = ''
    try { Set-PatrolCsvRowFields -CsvPath $wb -Id 'no-such-row' -Fields @{ status = 'x' } | Out-Null }
    catch { $errMissingId = $_.Exception.Message }
    Assert-True ($errMissingId -match 'no-such-row') 'write-back: unknown id raises a clear error' $errMissingId

    $dup = Join-Path $sandbox 'duplicate.csv'
    Write-Fixture -Path $dup -Text ("id,title,priority,interval`r`n" + "d-1,重复一,P0,0`r`n" + "d-1,重复二,P1,0`r`n")
    $errDup = ''
    try { Get-PatrolItems -CsvPath $dup | Out-Null } catch { $errDup = $_.Exception.Message }
    Assert-True ($errDup -match '重复') 'read: duplicate id raises a clear error' $errDup
}
finally {
    if ($KeepTemp) {
        Write-Host "kept sandbox: $sandbox"
    }
    else {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "summary pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }
exit 0
