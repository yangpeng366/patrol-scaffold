#requires -Version 7
<#
.SYNOPSIS
  command-adapter.ps1 — provider=command 的源适配器（第1层 Source Adapter）。

.DESCRIPTION
  数据源 = 「一次命令调用输出的 JSON」。命令由子进程 `pwsh -NoProfile -NonInteractive -Command`
  执行（工作目录 = 仓库根），因此命令串可以是任意 CLI 调用、管道或脚本：
  SCNet / 云厂商 CLI / sqlite3 / psql 导出 / 内部小工具，只要能吐 JSON，就能当源。

  与 csv-file / local-json 同一把尺子（三个契约函数），下游与 patrol-loop.ps1 一行不改：
    Get-PatrolItems   list-items()   跑命令 -> 解析 JSON -> 统一 item
    Save-PatrolItems  write-back()   只写本地镜像（命令源永远只读，不重放命令、不回写源）
    Resolve-ItemName  resolve-name() 摘要用可读名

  契约要点（每条都对应一个真实坑）：
    - stdout 必须整段是 JSON：首个非空字符只能是 '[' 或 '{'。CLI 把 banner / 进度日志
      打到 stdout 是这类源最常见的失败，报错会带首 200 字符，不静默当空源。
    - 退出码非 0 -> 抛错（带 stderr 尾部）。静默当空源会让「源挂了」看起来像「今天没活」。
    - 超时（默认 30s，`TimeoutSec` 可配）-> 杀进程树并抛错，避免一条挂死的命令拖死整轮。
    - 信封自动识别：顶层数组直接用；对象则按 items / records / list / data / rows 找数组
      （再往里一层也认）；复杂结构用 `ItemsPath`（如 `data.list`）指定，`.` 表示根。
    - 字段名可重映射：`FieldMap` 与 csv-file 的 columnMap 同一语法
      （`id=jobId;title=jobName;status=state;interval=intervalMin`），未写的键按 canonical 名回退。
    - 必填只有 id：缺 id 无法续跑与回写，报错点名「第几行 / id 映射到哪个属性 / 该行实际属性」。
      其余缺失一律交给装配层 ConvertTo-PatrolItem 兜（priority 非法降 P2、interval 转 int）。

  write-back 的边界（诚实版）：命令型源通常不能写回。这里把回写落到本地镜像
  `MirrorFile`（默认 state/command-mirror.json），只写非空字段、按 id upsert、写前比较，
  所以重复调用不会产生无意义 diff。要真写源，请在命令里显式实现（本适配器不代劳）。

.NOTES
  配置项见 adapters/command.adapter.json；接入清单与「何时只加 adapter / 何时动核心」
  见 docs/adapting-a-provider.md；mock 命令见 tests/fixtures/command/。
#>

# 统一无 BOM UTF-8（与 local-json / csv-file 一致）
$script:CmdNoBom = [System.Text.UTF8Encoding]::new($false)
$script:CmdRepoRoot = Split-Path -Parent $PSScriptRoot

# canonical 键 -> 含义（与 csv-file 的列键同一套语义，只多了 repo/thread/fake/lastRun）
$script:CmdKeys = @('id', 'title', 'priority', 'interval', 'status', 'action', 'note', 'repo', 'thread', 'fake', 'lastRun')

function Get-PatrolCommandClip {
    # 报错里只放截断后的片段：CLI 输出可能很长，也可能带不该回显的内容
    param([string]$Text, [int]$Max = 200)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { return $t }
    return ($t.Substring(0, $Max) + '…')
}

function Resolve-PatrolCommandFieldMap {
    # FieldMap 规格串 -> 有序字典（canonical key -> 源 JSON 属性名）；未写的键按 canonical 名回退
    param([string]$FieldMap)
    $map = [ordered]@{}
    foreach ($k in $script:CmdKeys) { $map[$k] = $k }
    if ([string]::IsNullOrWhiteSpace($FieldMap) -or $FieldMap -match '^\$\{') { return $map }
    foreach ($pair in ($FieldMap -split ';')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $kv = $pair.Split('=', 2)
        if ($kv.Count -ne 2) {
            throw ("command: fieldMap 片段 '{0}' 不是 key=属性名 形式（示例 id=jobId;title=jobName）" -f $pair.Trim())
        }
        $key = $kv[0].Trim().ToLowerInvariant()
        if ($key -eq 'intervalmin') { $key = 'interval' }
        if ($key -eq 'repopath') { $key = 'repo' }
        if ($key -eq 'threadid') { $key = 'thread' }
        $prop = $kv[1].Trim()
        if ($script:CmdKeys -notcontains $key) {
            throw ("command: fieldMap 键 '{0}' 不可识别，允许：{1}" -f $kv[0].Trim(), ($script:CmdKeys -join '/'))
        }
        if (-not $prop) { throw ("command: fieldMap 键 '{0}' 的属性名为空" -f $key) }
        $map[$key] = $prop
    }
    return $map
}

function Get-PatrolCommandProperty {
    # 从 PSCustomObject / IDictionary 取属性（ConvertFrom-Json 两种形态都兜）
    param($Node, [string]$Name)
    if ($null -eq $Node -or -not $Name) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) { if ([string]$k -ceq $Name) { return $Node[$k] } }
        foreach ($k in @($Node.Keys)) { if ([string]$k -ieq $Name) { return $Node[$k] } }
        return $null
    }
    if ($Node -is [string] -or $Node -is [ValueType]) { return $null }
    $p = $Node.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-PatrolCommandNodeKeys {
    param($Node)
    if ($null -eq $Node) { return @() }
    if ($Node -is [System.Collections.IDictionary]) { return @($Node.Keys | ForEach-Object { [string]$_ }) }
    if ($Node -is [string] -or $Node -is [ValueType]) { return @() }
    return @($Node.PSObject.Properties.Name)
}

function Test-PatrolCommandArray {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    return ($Value -is [System.Collections.IEnumerable])
}

function Get-PatrolCommandFieldValue {
    param($Row, [string]$Name)
    return (Get-PatrolCommandProperty -Node $Row -Name $Name)
}

function Select-PatrolCommandRows {
    # 从解析后的 JSON 里定位「行数组」。ItemsPath='.'（默认）走自动识别。
    param($Document, [string]$ItemsPath, [string]$IdField)

    $path = ([string]$ItemsPath).Trim()
    if ($path -and $path -ne '.' -and $path -ne '$') {
        $node = $Document
        foreach ($seg in ($path -split '\.')) {
            $s = $seg.Trim()
            if (-not $s) { continue }
            $node = Get-PatrolCommandProperty -Node $node -Name $s
            if ($null -eq $node) {
                throw ("command: itemsPath='{0}' 在输出里找不到（卡在 '{1}'）；该层可用键：{2}" -f $path, $s, ((Get-PatrolCommandNodeKeys $Document) -join ', '))
            }
        }
        if (-not (Test-PatrolCommandArray $node)) {
            throw ("command: itemsPath='{0}' 指向的不是数组（实得 {1}）" -f $path, $(if ($null -eq $node) { 'null' } else { $node.GetType().Name }))
        }
        return @($node)
    }

    if (Test-PatrolCommandArray $Document) { return @($Document) }

    # 信封：顶层是对象 -> 按常见键名找数组（含往里一层的 data.list 这种）
    foreach ($cand in @('items', 'records', 'list', 'rows', 'data')) {
        $v = Get-PatrolCommandProperty -Node $Document -Name $cand
        if (Test-PatrolCommandArray $v) { return @($v) }
        if ($null -ne $v -and -not ($v -is [string]) -and @(Get-PatrolCommandNodeKeys $v).Count -gt 0) {
            foreach ($inner in @('items', 'records', 'list', 'rows')) {
                $iv = Get-PatrolCommandProperty -Node $v -Name $inner
                if (Test-PatrolCommandArray $iv) { return @($iv) }
            }
        }
    }

    # 单行对象：带 id 映射的那个属性就当一条
    if ($IdField -and ($null -ne (Get-PatrolCommandProperty -Node $Document -Name $IdField))) {
        return @($Document)
    }

    throw ("command: 输出里没找到行数组（期望 JSON 数组，或带 items/records/list/data 的对象；复杂结构用 itemsPath 指定）。顶层键：{0}" -f ((Get-PatrolCommandNodeKeys $Document) -join ', '))
}

function ConvertTo-PatrolCommandItem {
    # 单行 -> 统一 item（只做映射与必填校验；非法 priority/interval 由装配层归一兜住）
    param($Row, $FieldMap, [int]$RowNo)
    if ($null -eq $Row -or $Row -is [string] -or $Row -is [ValueType]) {
        throw ("command: 第 {0} 行不是 JSON 对象（实得 {1}）；源应输出对象数组" -f $RowNo, $(if ($null -eq $Row) { 'null' } else { $Row.GetType().Name }))
    }

    $id = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['id'])).Trim()
    if (-not $id) {
        throw ("command: 第 {0} 行的 id 为空：fieldMap 把 id 映射到属性 '{1}'，该行实际属性：[{2}]。用 fieldMap 重映射（id=jobId;title=jobName;...）" -f
            $RowNo, $FieldMap['id'], ((Get-PatrolCommandNodeKeys $Row) -join ', '))
    }

    $title = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['title'])).Trim()
    if (-not $title) { $title = $id }

    $intervalRaw = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['interval'])).Trim()
    $interval = 0
    if ($intervalRaw) {
        $parsed = 0
        if (-not [int]::TryParse($intervalRaw, [ref]$parsed)) {
            throw ("command: 第 {0} 行（id={1}）的 interval 值 '{2}' 不是整数（属性 '{3}'）" -f $RowNo, $id, $intervalRaw, $FieldMap['interval'])
        }
        $interval = $parsed
    }

    $fakeRaw = Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['fake']
    $fake = $false
    if ($fakeRaw -is [bool]) { $fake = [bool]$fakeRaw }
    elseif ($null -ne $fakeRaw) {
        $s = ([string]$fakeRaw).Trim()
        if ($s -match '^(?i)(true|1|yes|y|on)$') { $fake = $true }
    }

    $thread = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['thread'])).Trim()
    $lastRun = Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['lastRun']

    return [pscustomobject][ordered]@{
        id           = $id
        title        = $title
        priority     = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['priority'])).Trim()
        intervalMin  = $interval
        repoPath     = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['repo'])).Trim()
        currentStage = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['status'])).Trim()
        nextStep     = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['action'])).Trim()
        description  = ([string](Get-PatrolCommandFieldValue -Row $Row -Name $FieldMap['note'])).Trim()
        threadId     = $(if ($thread) { $thread } else { $null })
        fake         = $fake
        lastRun      = $lastRun
    }
}

function ConvertFrom-PatrolCommandJson {
    # stdout -> JSON 文档（首个非空字符必须是 '[' 或 '{'）
    param([string]$Text, [string]$Command)
    $t = [string]$Text
    $t = $t.Trim([char[]]@([char]0xFEFF, ' ', "`t", "`r", "`n"))
    if (-not $t) {
        throw ("command: 命令没有任何输出（期望 stdout 是 JSON 数组）：{0}" -f (Get-PatrolCommandClip -Text $Command -Max 200))
    }
    $first = $t[0]
    if ($first -ne '[' -and $first -ne '{') {
        throw ("command: stdout 不是 JSON（首个非空字符是 '{0}'）。常见原因：CLI 把 banner / 进度日志打到了 stdout，或 JSON 前面有 shell 提示行。首 200 字符：{1}" -f
            $first, (Get-PatrolCommandClip -Text $t -Max 200))
    }
    try {
        return (ConvertFrom-Json -InputObject $t)
    }
    catch {
        throw ("command: stdout 像 JSON 但解析失败：{0}；首 200 字符：{1}" -f $_.Exception.Message, (Get-PatrolCommandClip -Text $t -Max 200))
    }
}

function Invoke-PatrolCommandProcess {
    # 子进程执行（独立进程边界：不污染当前会话的函数表，也真的是「调用一个 CLI」）
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 30,
        [string]$WorkingDirectory = ''
    )
    if ($TimeoutSec -le 0) { throw ("command: TimeoutSec 必须 > 0（实得 {0}）" -f $TimeoutSec) }

    $exe = 'pwsh'
    try {
        $self = (Get-Process -Id $PID).Path
        if ($self -and (Test-Path -LiteralPath $self)) { $exe = $self }
    }
    catch { }

    $cwd = [string]$WorkingDirectory
    if (-not $cwd) { $cwd = $script:CmdRepoRoot }
    if (-not (Test-Path -LiteralPath $cwd)) { $cwd = $script:CmdRepoRoot }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:CmdNoBom
    $psi.StandardErrorEncoding = $script:CmdNoBom
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-Command')
    # 把命令包进一个 scriptblock，再把原生命令的退出码透传出去：
    # `pwsh -Command "<cli>"` 默认只返回 0/1，真实 CLI 的 2（鉴权失败）/7（找不到目标）会被压成 1，
    # 排障时看不出是「命令跑错」还是「脚本写错」。$LASTEXITCODE 为 $null 表示没有原生命令参与，保持原样。
    $psi.ArgumentList.Add(('& {{ {0} }}; if ($null -ne $LASTEXITCODE) {{ exit $LASTEXITCODE }}' -f $Command))

    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
            throw ("command: 命令在 {0}s 内没有返回，已终止（按超时处理，避免拖死整轮）：{1}" -f $TimeoutSec, (Get-PatrolCommandClip -Text $Command -Max 200))
        }
        $p.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $p.ExitCode
            Stdout   = $outTask.GetAwaiter().GetResult()
            Stderr   = $errTask.GetAwaiter().GetResult()
            Command  = $Command
        }
    }
    finally {
        $p.Dispose()
    }
}

function Resolve-PatrolCommandMirrorPath {
    param([string]$MirrorFile)
    $m = ([string]$MirrorFile).Trim()
    if (-not $m -or $m -match '^\$\{') {
        throw 'command: 未指定本地镜像文件（-MirrorFile <file.json>、描述文件 config.mirrorFile，或环境变量 PATROL_COMMAND_MIRRORFILE）'
    }
    if ([System.IO.Path]::IsPathRooted($m)) { return $m }
    return (Join-Path $script:CmdRepoRoot $m)
}

function Get-PatrolItems {
    # list-items(): 跑一次命令 -> 解析 -> 每行归一
    param(
        [string]$Command = '',
        [string]$FieldMap = '',
        [string]$ItemsPath = '.',
        [string]$TimeoutSec = '30'
    )
    $cmd = ([string]$Command).Trim()
    if (-not $cmd -or $cmd -match '^\$\{') {
        throw 'command: 未指定数据源命令（-Command "<CLI>"、描述文件 config.command，或环境变量 PATROL_COMMAND_COMMAND）'
    }

    $timeout = 30
    $ts = ([string]$TimeoutSec).Trim()
    if ($ts -and $ts -notmatch '^\$\{') {
        if (-not [int]::TryParse($ts, [ref]$timeout)) {
            throw ("command: TimeoutSec '{0}' 不是整数" -f $TimeoutSec)
        }
    }

    $map = Resolve-PatrolCommandFieldMap -FieldMap $FieldMap
    $run = Invoke-PatrolCommandProcess -Command $cmd -TimeoutSec $timeout
    if ($run.ExitCode -ne 0) {
        throw ("command: 命令退出码 {0}（按读取失败处理，不当空源）。stderr：{1}；stdout：{2}" -f
            $run.ExitCode, (Get-PatrolCommandClip -Text $run.Stderr -Max 400), (Get-PatrolCommandClip -Text $run.Stdout -Max 200))
    }

    $doc = ConvertFrom-PatrolCommandJson -Text $run.Stdout -Command $cmd
    $rows = @(Select-PatrolCommandRows -Document $doc -ItemsPath $ItemsPath -IdField $map['id'])

    $items = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $i = 0
    foreach ($row in $rows) {
        $i++
        $it = ConvertTo-PatrolCommandItem -Row $row -FieldMap $map -RowNo $i
        if (-not $seen.Add([string]$it.id)) {
            throw ("command: 第 {0} 行的 id '{1}' 与前面重复；id 必须唯一（否则无法续跑与回写）" -f $i, $it.id)
        }
        $items.Add($it)
    }
    return $items.ToArray()
}

function Save-PatrolItems {
    # write-back(): 只落本地镜像。命令源永远只读：不重放命令、不改源系统。
    # 只写非空字段；按 id upsert；写前比较，无变化则不落盘（幂等）。
    param(
        [string]$MirrorFile = '',
        [Parameter(Mandatory)]$Items
    )
    $path = Resolve-PatrolCommandMirrorPath -MirrorFile $MirrorFile

    $rows = [ordered]@{}
    $before = @{}
    if (Test-Path -LiteralPath $path) {
        $raw = [System.IO.File]::ReadAllText($path, $script:CmdNoBom)
        if ($raw.Trim()) {
            $doc = ConvertFrom-Json -InputObject $raw
            $existing = Get-PatrolCommandProperty -Node $doc -Name 'rows'
            if ($null -ne $existing) {
                foreach ($k in @(Get-PatrolCommandNodeKeys $existing)) {
                    $v = Get-PatrolCommandProperty -Node $existing -Name $k
                    $rows[$k] = $v
                    $before[$k] = (ConvertTo-Json -InputObject $v -Depth 6 -Compress)
                }
            }
        }
    }

    $changed = 0
    foreach ($it in @($Items)) {
        $id = ([string]$it.id).Trim()
        if (-not $id) { throw 'command: Save-PatrolItems 收到没有 id 的 item' }

        $patch = [ordered]@{}
        foreach ($src in @(
                @{ Key = 'currentStage'; Value = [string]$it.currentStage },
                @{ Key = 'nextStep'; Value = [string]$it.nextStep },
                @{ Key = 'achievement'; Value = [string]$it.achievement },
                @{ Key = 'threadId'; Value = [string]$it.threadId },
                @{ Key = 'lastRun'; Value = [string]$it.lastRun })) {
            if ($src.Value) { $patch[$src.Key] = $src.Value }
        }
        if ($patch.Count -eq 0) { continue }

        if ($rows.Contains($id)) {
            foreach ($k in @($patch.Keys)) { $rows[$id].$k = $patch[$k] }
        }
        else {
            $rows[$id] = [pscustomobject]$patch
        }
        $after = (ConvertTo-Json -InputObject $rows[$id] -Depth 6 -Compress)
        if (-not $before.ContainsKey($id) -or $before[$id] -cne $after) { $changed++ }
    }
    if ($changed -eq 0) { return 0 }

    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $doc = [ordered]@{
        provider  = 'command'
        note      = 'write-back 只落本地镜像：命令型源永远只读，不重放命令、不回写源'
        writtenAt = (Get-Date).ToString('o')
        rows      = $rows
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 8
    $tmp = ('{0}.tmp-{1}' -f $path, $PID)
    [System.IO.File]::WriteAllText($tmp, $json, $script:CmdNoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $changed
}

function Resolve-ItemName {
    # resolve-name(): 摘要用可读名
    param($Item)
    if (-not $Item) { return '' }
    $t = [string]$Item.title
    if ($t) { return $t }
    return [string]$Item.id
}
