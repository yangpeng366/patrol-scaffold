#requires -Version 7
<#
.SYNOPSIS
  verify-command-adapter.ps1 — provider=command 的离线自测（全部在 %TEMP% 沙箱里造命令与镜像）。

.DESCRIPTION
  直接 dot-source scripts/command-adapter.ps1，不联网、不装依赖、不碰仓内 state/：
    1) 正常读取：mock 命令 3 行、fieldMap 重映射、中文、interval=0、repoPath
    2) 信封：{code,data:{list:[...]}} 自动识别 + itemsPath='data.list' 显式指定
    3) 单元素数组（-Count 1）不被解包成对象
    4) 退出码非 0 -> 抛错并回显退出码与 stderr（不当空源）
    5) stdout 带 banner（不是 JSON）-> 抛错并回显首段输出
    6) 空 stdout -> 抛错
    7) 超时 -> 抛错（TimeoutSec=1，命令 sleep）
    8) fieldMap 键名不可识别 / id 映射错 / id 重复 / 行不是对象 / itemsPath 不存在 -> 各自点名报错
    9) write-back：只落本地镜像、只写非空字段、按 id upsert、幂等（0 变化不落盘）、不重放命令
    10) 跨 provider 形状一致：与 local-json 归一后的 item 键集合相同
    11) 契约覆盖：子进程跑 scripts/adapter-contract-test.ps1 -Provider command 必须 PASS

.PARAMETER KeepTemp
  保留沙箱目录以便人工复核（默认跑完清理）。

.EXAMPLE
  pwsh -NoProfile -File tests/verify-command-adapter.ps1
#>
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$adapterPath = Join-Path $root 'scripts\command-adapter.ps1'
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

function Read-Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function New-SandboxScript {
    # 造一个可执行的小命令（负面用例用），返回可直接喂给 -Command 的命令串
    param([string]$Name, [string]$Body)
    $p = Join-Path $script:sandbox $Name
    Write-Fixture -Path $p -Text $Body
    return ('pwsh -NoProfile -File "{0}"' -f $p)
}

function Get-ErrorMessage {
    # 跑一段必然抛错的调用，返回异常文本（不吞细节）
    param([scriptblock]$Block)
    try { & $Block | Out-Null; return '' }
    catch { return $_.Exception.Message }
}

$sandbox = Join-Path $env:TEMP ('command-adapter-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
Write-Host "sandbox: $sandbox"

$mockJobs = ('pwsh -NoProfile -File "{0}"' -f (Join-Path $root 'tests\fixtures\command\mock-jobs.ps1'))
$mockEnvelope = ('pwsh -NoProfile -File "{0}"' -f (Join-Path $root 'tests\fixtures\command\mock-scnet-jobs.ps1'))
$fieldMap = 'id=jobId;title=jobName;priority=priority;interval=intervalMin;status=state;action=nextStep;note=note;repo=repo'

try {
    # ---------------------------------------------------------------------
    # 1) 正常读取
    # ---------------------------------------------------------------------
    $items = @(Get-PatrolItems -Command $mockJobs -FieldMap $fieldMap)
    Assert-True ($items.Count -eq 3) 'basic: 3 rows from the mock command' "got $($items.Count)"
    Assert-True ((($items | ForEach-Object { $_.id }) -join ',') -eq 'job-101,job-102,job-103') 'basic: ids in command order' (($items | ForEach-Object { $_.id }) -join ',')
    Assert-True ($items[0].title -eq 'SCNet 队列巡检') 'basic: fieldMap title=jobName + UTF-8 中文未被破坏' "title=[$($items[0].title)]"
    Assert-True ($items[0].currentStage -eq '进行中') 'basic: fieldMap status=state' "status=[$($items[0].currentStage)]"
    Assert-True ($items[0].nextStep -eq '核对队列配额') 'basic: fieldMap action=nextStep' "action=[$($items[0].nextStep)]"
    Assert-True ($items[0].intervalMin -eq 30 -and $items[1].intervalMin -eq 60) 'basic: fieldMap interval=intervalMin -> int' "a=$($items[0].intervalMin) b=$($items[1].intervalMin)"
    Assert-True ($items[2].intervalMin -eq 0) 'basic: interval 0 preserved (0 = due every round)' "got $($items[2].intervalMin)"
    Assert-True ($items[0].repoPath -eq $root -and $items[2].repoPath -eq '') 'basic: fieldMap repo=repo（空值留空，不臆造）' "a=[$($items[0].repoPath)] c=[$($items[2].repoPath)]"
    Assert-True ($items[0].priority -eq 'P0') 'basic: fieldMap priority' "priority=[$($items[0].priority)]"
    Assert-True ((Resolve-ItemName -Item $items[0]) -eq 'SCNet 队列巡检') 'basic: resolve-name returns the title'
    Assert-True ([string](Resolve-ItemName -Item ([pscustomobject]@{ id = 'x' })) -eq 'x') 'basic: resolve-name falls back to id'

    # ---------------------------------------------------------------------
    # 2) 信封：自动识别 + itemsPath 显式指定
    # ---------------------------------------------------------------------
    $envMap = 'id=id;title=name;priority=priority;interval=intervalMin;status=status;action=nextStep;note=note;repo=repo'
    $auto = @(Get-PatrolItems -Command $mockEnvelope -FieldMap $envMap)
    Assert-True ($auto.Count -eq 2) 'envelope: {code,data:{list:[...]}} auto-detected' "got $($auto.Count)"
    Assert-True ($auto[0].id -eq 'scnet-9001') 'envelope: row read through data.list' "id=[$($auto[0].id)]"

    $explicit = @(Get-PatrolItems -Command $mockEnvelope -FieldMap $envMap -ItemsPath 'data.list')
    Assert-True ($explicit.Count -eq 2 -and $explicit[1].id -eq 'scnet-9002') 'envelope: itemsPath=data.list explicit' "got $($explicit.Count)"

    $badPath = Get-ErrorMessage { Get-PatrolItems -Command $mockEnvelope -FieldMap $envMap -ItemsPath 'data.nope' }
    Assert-True ($badPath -match 'itemsPath' -and $badPath -match 'nope') 'envelope: unknown itemsPath raises a naming error' $badPath

    # ---------------------------------------------------------------------
    # 3) 单元素数组不被解包
    # ---------------------------------------------------------------------
    $one = @(Get-PatrolItems -Command ($mockJobs + ' -Count 1') -FieldMap $fieldMap)
    Assert-True ($one.Count -eq 1 -and $one[0].id -eq 'job-101') 'single: one-element JSON array stays one row' "got $($one.Count)"

    # ---------------------------------------------------------------------
    # 4) 退出码非 0
    # ---------------------------------------------------------------------
    $failCmd = New-SandboxScript -Name 'fail.ps1' -Body @'
[Console]::Error.WriteLine('boom: cluster not found')
exit 7
'@
    $err = Get-ErrorMessage { Get-PatrolItems -Command $failCmd -FieldMap $fieldMap }
    # 退出码必须是 7 本身（不是被 pwsh 压成 1）：真实 CLI 的 2/7 是排障线索
    Assert-True (($err -match '退出码 7') -and ($err -match 'boom: cluster not found')) 'exit code: non-zero fails loudly with the real code (7) + stderr' $err

    # ---------------------------------------------------------------------
    # 5) stdout 带 banner（不是纯 JSON）
    # ---------------------------------------------------------------------
    $bannerCmd = New-SandboxScript -Name 'banner.ps1' -Body @'
Write-Output 'loading jobs...'
Write-Output '[{"jobId":"b-1","jobName":"banner row"}]'
'@
    $err = Get-ErrorMessage { Get-PatrolItems -Command $bannerCmd -FieldMap $fieldMap }
    Assert-True (($err -match 'stdout 不是 JSON') -and ($err -match 'loading jobs')) 'banner: non-JSON stdout fails and echoes the first characters' $err

    # ---------------------------------------------------------------------
    # 6) 空 stdout
    # ---------------------------------------------------------------------
    $emptyCmd = New-SandboxScript -Name 'empty.ps1' -Body '# 什么都不输出'
    $err = Get-ErrorMessage { Get-PatrolItems -Command $emptyCmd -FieldMap $fieldMap }
    Assert-True ($err -match '没有任何输出') 'empty: empty stdout fails instead of silently returning 0 rows' $err

    # ---------------------------------------------------------------------
    # 7) 超时
    # ---------------------------------------------------------------------
    $slowCmd = New-SandboxScript -Name 'slow.ps1' -Body @'
Start-Sleep -Seconds 20
'@
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $err = Get-ErrorMessage { Get-PatrolItems -Command $slowCmd -FieldMap $fieldMap -TimeoutSec '1' }
    $sw.Stop()
    Assert-True (($err -match '没有返回') -and ($sw.Elapsed.TotalSeconds -lt 15)) 'timeout: hung command is killed and fails (no round-wide hang)' ("err=$err elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,1))s")

    # ---------------------------------------------------------------------
    # 8) fieldMap / id / 重复 id / 非对象行
    # ---------------------------------------------------------------------
    $err = Get-ErrorMessage { Get-PatrolItems -Command $mockJobs -FieldMap 'bogus=jobId' }
    Assert-True (($err -match 'bogus') -and ($err -match '不可识别')) 'fieldMap: unknown canonical key is named' $err

    $err = Get-ErrorMessage { Get-PatrolItems -Command $mockJobs -FieldMap 'id=nope' }
    Assert-True (($err -match "'nope'") -and ($err -match '第 1 行') -and ($err -match 'jobId')) 'fieldMap: unmapped id names the row, the mapped property and the real keys' $err

    $dupCmd = New-SandboxScript -Name 'dupid.ps1' -Body @'
Write-Output '[{"jobId":"d-1","jobName":"a"},{"jobId":"d-1","jobName":"b"}]'
'@
    $err = Get-ErrorMessage { Get-PatrolItems -Command $dupCmd -FieldMap $fieldMap }
    Assert-True ($err -match '重复') 'rows: duplicate id raises a clear error' $err

    $scalarCmd = New-SandboxScript -Name 'scalar.ps1' -Body @'
Write-Output '[1,2]'
'@
    $err = Get-ErrorMessage { Get-PatrolItems -Command $scalarCmd -FieldMap $fieldMap }
    Assert-True ($err -match '不是 JSON 对象') 'rows: scalar rows are rejected with a naming error' $err

    $badIntervalCmd = New-SandboxScript -Name 'badinterval.ps1' -Body @'
Write-Output '[{"jobId":"i-1","jobName":"x","intervalMin":"soon"}]'
'@
    $err = Get-ErrorMessage { Get-PatrolItems -Command $badIntervalCmd -FieldMap $fieldMap }
    Assert-True (($err -match '不是整数') -and ($err -match 'i-1')) 'interval: non-integer value names the row id' $err

    # ---------------------------------------------------------------------
    # 9) write-back：本地镜像、只写非空、upsert、幂等、不重放命令
    # ---------------------------------------------------------------------
    $marker = Join-Path $sandbox 'replay-marker.txt'
    $markerBody = @'
Add-Content -LiteralPath '__MARKER__' -Value 'invoked'
Write-Output '[{"jobId":"m-1","jobName":"镜像行","state":"待开始"}]'
'@
    $markerCmd = New-SandboxScript -Name 'marker.ps1' -Body ($markerBody.Replace('__MARKER__', $marker.Replace("'", "''")))
    $mirror = Join-Path $sandbox 'mirror\command-mirror.json'

    $mItems = @(Get-PatrolItems -Command $markerCmd -FieldMap $fieldMap)
    Assert-True ((Test-Path -LiteralPath $marker) -and @(Get-Content -LiteralPath $marker).Count -eq 1) 'writeback: list-items runs the command exactly once' "marker lines=$(if (Test-Path $marker) { @(Get-Content $marker).Count } else { 'missing' })"

    $mItems[0].currentStage = '完成(dry-run)'
    $mItems[0] | Add-Member -NotePropertyName achievement -NotePropertyValue 'dry-run: 模拟完成' -Force
    $mItems[0].threadId = 'thread-abc'
    $changed = Save-PatrolItems -MirrorFile $mirror -Items @($mItems[0])
    Assert-True ($changed -eq 1) 'writeback: one row reported changed' "changed=$changed"
    Assert-True (Test-Path -LiteralPath $mirror) 'writeback: mirror file created' "path=$mirror"
    $mirrorDoc = Read-Text -Path $mirror | ConvertFrom-Json
    Assert-True ($mirrorDoc.provider -eq 'command') 'writeback: mirror records the provider'
    Assert-True ($mirrorDoc.rows.'m-1'.currentStage -eq '完成(dry-run)') 'writeback: currentStage landed in the mirror' "got=$($mirrorDoc.rows.'m-1'.currentStage)"
    Assert-True ($mirrorDoc.rows.'m-1'.achievement -eq 'dry-run: 模拟完成') 'writeback: achievement landed in the mirror'
    Assert-True ($mirrorDoc.rows.'m-1'.threadId -eq 'thread-abc') 'writeback: threadId landed in the mirror'
    Assert-True (@(Get-Content -LiteralPath $marker).Count -eq 1) 'writeback: never replays the command (source stays read-only)' "marker lines=$(@(Get-Content -LiteralPath $marker).Count)"

    $mirrorBytes = (Get-FileHash -LiteralPath $mirror -Algorithm SHA256).Hash
    $again = Save-PatrolItems -MirrorFile $mirror -Items @($mItems[0])
    $mirrorBytes2 = (Get-FileHash -LiteralPath $mirror -Algorithm SHA256).Hash
    Assert-True ($again -eq 0) 'writeback: same values -> 0 changes' "changed=$again"
    Assert-True ($mirrorBytes -eq $mirrorBytes2) 'writeback: idempotent (file not rewritten on a no-op)'

    $emptyPatch = Save-PatrolItems -MirrorFile (Join-Path $sandbox 'mirror\none.json') -Items @([pscustomobject]@{ id = 'x-1'; currentStage = ''; nextStep = ''; achievement = '' })
    Assert-True ($emptyPatch -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $sandbox 'mirror\none.json'))) 'writeback: empty fields write nothing (never blanks the source)' "changed=$emptyPatch"

    $bom = [System.IO.File]::ReadAllBytes($mirror)
    Assert-True (-not ($bom.Length -ge 3 -and $bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) 'writeback: mirror is UTF-8 without BOM'

    $err = Get-ErrorMessage { Save-PatrolItems -MirrorFile '${mirrorFile}' -Items @($mItems[0]) }
    Assert-True ($err -match '未指定本地镜像文件') 'writeback: an unexpanded placeholder is refused (not written as a literal name)' $err

    # ---------------------------------------------------------------------
    # 10) 跨 provider 形状一致（归一后与 local-json 同一把尺子）
    #     在子进程里装配：装配层靠「dot-source 前后的函数正文快照」判定谁装了哪些函数，
    #     同一会话里已经直接 dot-source 过适配器时再 Import 会被当成「函数已存在」而跳过登记
    #     （见 docs/adapting-a-provider.md 的「坑」一节）。真实运行（patrol-loop / 契约自测）
    #     永远只走装配层、不直连模块，所以这里按真实用法分进程验。
    # ---------------------------------------------------------------------
    $parityScript = Join-Path $sandbox 'parity.ps1'
    $parityBody = @'
$ErrorActionPreference = 'Stop'
$root = '__ROOT__'
. (Join-Path $root 'scripts\patrol-provider.ps1')
$tasksFile = Join-Path $root 'scripts\sample-tasks.json'
$cmd = Import-PatrolProvider -Provider 'command' -Values @{ tasksFile = $tasksFile }
$lj = Import-PatrolProvider -Provider 'local-json' -Values @{ tasksFile = $tasksFile }
$ci = @(Get-PatrolProviderItems -Provider $cmd)
$li = @(Get-PatrolProviderItems -Provider $lj)
[pscustomobject]@{
  cmdCount = $ci.Count
  ljCount  = $li.Count
  cmdKeys  = @($ci[0].PSObject.Properties.Name | Sort-Object)
  ljKeys   = @($li[0].PSObject.Properties.Name | Sort-Object)
  priorityType    = $ci[0].priority.GetType().Name
  intervalMinType = $ci[0].intervalMin.GetType().Name
  fakeType        = $ci[0].fake.GetType().Name
  shape = @($ci | ForEach-Object { '{0}|{1}|{2}' -f $_.priority, $_.intervalMin.GetType().Name, $_.fake.GetType().Name } | Sort-Object -Unique)
} | ConvertTo-Json -Depth 5
'@
    Write-Fixture -Path $parityScript -Text ($parityBody.Replace('__ROOT__', $root.Replace("'", "''")))
    $parityJson = (& pwsh -NoProfile -File $parityScript 2>&1 | Out-String)
    $parityCode = $LASTEXITCODE
    Assert-True ($parityCode -eq 0) 'parity: child assembly of command + local-json succeeded' "exit=$parityCode out=$($parityJson.Trim())"
    $parity = $parityJson | ConvertFrom-Json
    Assert-True (($parity.cmdCount -eq 3) -and ($parity.ljCount -gt 0)) 'parity: both providers list rows through the assembly layer' "cmd=$($parity.cmdCount) lj=$($parity.ljCount)"
    $cmdKeys = (@($parity.cmdKeys) -join ',')
    $ljKeys = (@($parity.ljKeys) -join ',')
    Assert-True ($cmdKeys -eq $ljKeys) 'parity: command and local-json normalize to the same item key set' "cmd=[$cmdKeys] lj=[$ljKeys]"
    Assert-True (($parity.priorityType -eq 'String') -and ($parity.intervalMinType -eq 'Int32') -and ($parity.fakeType -eq 'Boolean')) 'parity: normalized types match the schema (string/int/bool)' "priority=$($parity.priorityType) interval=$($parity.intervalMinType) fake=$($parity.fakeType)"
    $cmdShape = @($parity.shape)
    $shapeOk = ($cmdShape.Count -gt 0) -and (@($cmdShape | Where-Object { $_ -notmatch '^P[012]\|Int32\|Boolean$' }).Count -eq 0)
    Assert-True $shapeOk 'parity: every row has the same normalized types (priority P0/P1/P2 kept)' ($cmdShape -join ' ; ')

    # ---------------------------------------------------------------------
    # 11) 契约自测覆盖（子进程跑现有闸门，只验这一家）
    # ---------------------------------------------------------------------
    $contractOut = (& pwsh -NoProfile -File (Join-Path $root 'scripts\adapter-contract-test.ps1') -Provider command 2>&1 | Out-String)
    $contractCode = $LASTEXITCODE
    Assert-True (($contractCode -eq 0) -and ($contractOut -match '\[PASS\] command')) 'gate: adapter-contract-test.ps1 -Provider command passes' "exit=$contractCode out=$($contractOut.Trim())"

    $specOut = (& pwsh -NoProfile -File (Join-Path $root 'tests\verify-adapter-spec.ps1') -NoSelfTest 2>&1 | Out-String)
    $specCode = $LASTEXITCODE
    Assert-True (($specCode -eq 0) -and ($specOut -match 'PASS\] adapters/command\.adapter\.json')) 'gate: verify-adapter-spec.ps1 passes for the command descriptor' "exit=$specCode"
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
