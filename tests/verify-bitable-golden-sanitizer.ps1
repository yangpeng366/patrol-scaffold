#requires -Version 7
<#
    Offline regression proof for tests/record-bitable-golden.ps1.

    The fixture contains one sentinel in every kind of cell the sanitizer must
    cover: text, a user object, an attachment object, lookup / formula objects,
    and a link to another selected row. The capture must either remove every
    sentinel or fail before writing a file.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sanitizer = Join-Path $PSScriptRoot 'record-bitable-golden.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('patrol-golden-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = [System.Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-RawTable {
    $fields = [System.Collections.Generic.List[string]]::new()
    $types = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string]$Name, [string]$Type)
        $fields.Add($Name)
        $types.Add($Type)
    }

    & $add '项目名' 'text'
    & $add '难度' 'select'
    & $add '分类' 'select'
    & $add '假数据模式' 'checkbox'
    & $add '授权边界' 'select'
    & $add '用户批注' 'text'
    & $add '审批状态' 'select'
    & $add '优先级' 'select'
    & $add '最近执行时间' 'datetime'
    & $add '父记录' 'link'
    & $add 'GitHub' 'text'
    & $add '巡检占用' 'text'
    & $add '协作形态' 'select'
    & $add 'codex_thread_id' 'text'
    & $add '待审行动' 'text'
    & $add '动作类型' 'select'
    & $add '最近结果' 'select'
    & $add '仓库路径' 'text'
    & $add '贡献类型' 'select'
    & $add '当前阶段' 'select'
    & $add '外部成就' 'text'
    & $add '会话ID' 'text'
    & $add '巡检间隔(分钟)' 'number'
    & $add '目标' 'text'
    & $add '下一步' 'text'
    & $add '简要描述' 'text'
    & $add '相关文档' 'text'
    & $add '执行器' 'select'
    & $add '衡量指标' 'text'
    & $add '用户对象' 'user'
    & $add '附件' 'attachment'
    & $add '查找' 'lookup'
    & $add '公式' 'formula'

    $row1 = [System.Collections.Generic.List[object]]::new()
    $row2 = [System.Collections.Generic.List[object]]::new()
    $addCell = {
        param($Row, $Value)
        $Row.Add($Value)
    }

    $values1 = @(
        'SECRET PROJECT NAME', '入门', '工作项目', $true, '自主', 'SECRET NOTE',
        '已通过', 'P1', '2026-11-11T08:00:00.000+08:00', @([ordered]@{ id = 'recReal2'; text = 'SECRET PARENT' }),
        'https://github.com/secret-org/secret-repo', 'SECRET OCCUPANCY', 'sparse',
        '123e4567-e89b-12d3-a456-426614174000', 'SECRET PENDING', 'decision', '成功',
        'D:\secret\repo', 'bug修复', '开发', 'SECRET ACHIEVEMENT',
        'mvs_abcdefghijklmnopqrstuvwx', 0, 'SECRET GOAL', 'SECRET NEXT', 'SECRET DESCRIPTION',
        'SECRET DOC', 'mcode', 'SECRET METRIC',
        @([ordered]@{
            id = 'ou_1234567890abcdef1234567890abcdef'
            name = 'SECRET USER'
            en_name = 'Secret User'
            email = 'secret@example.com'
            avatar_url = 'https://internal.example/avatar?token=SECRET'
        }),
        @([ordered]@{ file_token = 'file_SECRET_TOKEN'; name = 'secret-file.txt'; url = 'https://internal.example/file'; size = 42; type = 'file' }),
        @([ordered]@{ text = 'LOOKUP SECRET'; id = 'recLookupReal' }),
        @([ordered]@{ value = 'FORMULA SECRET'; type = 'text' })
    )
    $values2 = @(
        'SECOND SECRET NAME', '中等', '兴趣研究', $false, '只读', 'SECOND NOTE',
        '待审', 'P2', 1767580800000, @([ordered]@{ id = 'recReal1'; text = 'SECOND PARENT' }),
        'https://github.com/secret-org/second-repo', 'SECOND OCCUPANCY', 'approve',
        'mvs_zyxwvutsrqponmlkjihgfedc', 'SECOND PENDING', 'unclear', '失败',
        'https://internal.example/second-repo', '文档完善', '维护', 'SECOND ACHIEVEMENT',
        '00000000-0000-4000-8000-abcdefabcdef', 30, 'SECOND GOAL', 'SECOND NEXT', 'SECOND DESCRIPTION',
        'SECOND DOC', 'codex', 'SECOND METRIC',
        @([ordered]@{ id = 'ou_abcdefabcdefabcdefabcdefabcdefab'; name = 'SECOND USER' }),
        @([ordered]@{ file_token = 'file_SECOND_TOKEN'; name = 'second.txt'; url = 'https://internal.example/second' }),
        'LOOKUP SECOND',
        'FORMULA SECOND'
    )
    foreach ($v in $values1) { & $addCell $row1 $v }
    foreach ($v in $values2) { & $addCell $row2 $v }
    # 飞书对这几列返回单元素数组；PowerShell 的 @(...) 会把单元素数组展平成标量，
    # 所以这里显式转回 [object[]]，否则夹具本身就不是真实形状。
    foreach ($column in @('父记录', '用户对象', '附件', '查找', '公式')) {
        $index = $fields.IndexOf($column)
        $row1[$index] = [object[]]@($row1[$index])
        $row2[$index] = [object[]]@($row2[$index])
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add([object[]]$row1.ToArray())
    $rows.Add([object[]]$row2.ToArray())
    $fieldIds = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $fields) { $fieldIds.Add(('fld_' + [guid]::NewGuid().ToString('N').Substring(0, 7))) }

    return [ordered]@{
        ok       = $true
        identity = 'user'
        data     = [ordered]@{
            fields          = [object[]]$fields.ToArray()
            field_id_list   = [object[]]$fieldIds.ToArray()
            field_type_list = [object[]]$types.ToArray()
            data            = [object[]]$rows.ToArray()
            record_id_list  = [object[]]@('recReal1', 'recReal2')
            has_more        = $false
            rev             = 4424
            timezone        = 'Asia/Shanghai'
        }
    }
}

function Invoke-Sanitizer {
    param([string]$RawPath, [string]$OutPath)
    $output = & pwsh -NoProfile -File $sanitizer -RawJson $RawPath -Out $OutPath -MaxTextLength 64 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

try {
    $raw = New-RawTable
    $rawPath = Join-Path $tmp 'raw.json'
    $outPath = Join-Path $tmp 'golden.json'
    [System.IO.File]::WriteAllText($rawPath, ($raw | ConvertTo-Json -Depth 30), $utf8)

    $run = Invoke-Sanitizer -RawPath $rawPath -OutPath $outPath
    Assert-True ($run.ExitCode -eq 0) ("sanitizer failed:`n" + $run.Output)
    $text = [System.IO.File]::ReadAllText($outPath)
    foreach ($sentinel in @(
        'SECRET', 'secret-org', 'ou_1234567890abcdef1234567890abcdef',
        'file_SECRET_TOKEN', 'LOOKUP SECRET', 'FORMULA SECRET', 'github.com', 'internal.example'
    )) {
        Assert-True (-not $text.Contains($sentinel, [System.StringComparison]::OrdinalIgnoreCase)) ("leaked sentinel: " + $sentinel)
    }

    $golden = $text | ConvertFrom-Json -AsHashtable -DateKind String
    $fields = @($golden.data.fields)
    $row1 = $golden.data.data[0]
    $user = $row1[$fields.IndexOf('用户对象')]
    $attachment = $row1[$fields.IndexOf('附件')]
    $lookup = $row1[$fields.IndexOf('查找')]
    $formula = $row1[$fields.IndexOf('公式')]
    $parent = $row1[$fields.IndexOf('父记录')]
    $timestamp = $row1[$fields.IndexOf('最近执行时间')]
    $epoch = $golden.data.data[1][$fields.IndexOf('最近执行时间')]

    Assert-True ($user -is [array] -and $user.Count -eq 1) 'user cell lost its array shape'
    Assert-True ($user[0].id -match '^ou_[0-9a-f]{32}$') 'user open_id is not a fake open_id'
    Assert-True ([string]$user[0].name -like '[[]虚构]*') 'user name was not replaced'
    Assert-True ($user[0].avatar_url -eq 'https://example.invalid/structured') 'user avatar URL was not replaced'
    Assert-True ($attachment -is [array] -and $attachment[0].file_token -match '^[A-Za-z]{2,6}_[0-9a-z]+$') 'attachment token shape drifted'
    Assert-True ($attachment[0].url -eq 'https://example.invalid/structured') 'attachment URL was not replaced'
    Assert-True ($lookup -is [array] -and $formula -is [array]) 'lookup/formula array shape was lost'
    Assert-True ($parent -is [array] -and $parent[0].id -eq (@($golden.data.record_id_list)[1])) 'parent link does not point at the selected record'
    Assert-True ($timestamp -match '^2026-01-\d{2}T09:\d{2}:00\.000\+08:00$') 'datetime string shape drifted'
    Assert-True ($epoch -is [long] -and $epoch -gt 1700000000000) 'numeric epoch changed to a string'

    # An unknown select option must fail closed, not be copied into the sample.
    $bad = New-RawTable
    $bad.data.fields = [object[]](@($bad.data.fields) + @('未知分类'))
    $bad.data.field_type_list = [object[]](@($bad.data.field_type_list) + @('select'))
    $bad.data.field_id_list = [object[]](@($bad.data.field_id_list) + @('fld_UNKNOWN'))
    $badRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($bad.data.data)) {
        $badRows.Add([object[]](@($r) + @('SECRET OPTION')))
    }
    $bad.data.data = [object[]]$badRows.ToArray()
    $badPath = Join-Path $tmp 'bad-select.json'
    $badOut = Join-Path $tmp 'bad-select-out.json'
    [System.IO.File]::WriteAllText($badPath, ($bad | ConvertTo-Json -Depth 30), $utf8)
    $badRun = Invoke-Sanitizer -RawPath $badPath -OutPath $badOut
    Assert-True ($badRun.ExitCode -ne 0) 'unknown select option did not fail'
    Assert-True (-not (Test-Path -LiteralPath $badOut)) 'failed capture wrote an output file'

    # A row whose width disagrees with fields must fail before any cell is read.
    $short = New-RawTable
    $short.data.data[0] = [object[]](@($short.data.data[0])[0..20])
    $shortPath = Join-Path $tmp 'short-row.json'
    $shortOut = Join-Path $tmp 'short-row-out.json'
    [System.IO.File]::WriteAllText($shortPath, ($short | ConvertTo-Json -Depth 30), $utf8)
    $shortRun = Invoke-Sanitizer -RawPath $shortPath -OutPath $shortOut
    Assert-True ($shortRun.ExitCode -ne 0) 'mismatched row width did not fail'
    Assert-True (-not (Test-Path -LiteralPath $shortOut)) 'mismatched row wrote an output file'

    Write-Host 'RESULT: PASS'
    exit 0
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
