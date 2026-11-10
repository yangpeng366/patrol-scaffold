#requires -Version 7
<#
  tests/fixtures/command/mock-scnet-jobs.ps1 — 带信封的 mock 命令（模拟 SCNet / 云厂商 CLI 的返回形态）。

  stdout 是一个对象而不是数组：{ "code": 0, "message": "ok", "data": { "total": 2, "list": [...] } }
  适配器默认按 items / records / list / data / rows 自动识别信封，也可以用 itemsPath='data.list' 显式指定。
  字段名也不同（id / name / status / intervalMin），同样靠 fieldMap 重映射。

  用法：
    pwsh -NoProfile -File tests/fixtures/command/mock-scnet-jobs.ps1
#>
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

$list = @(
    [ordered]@{
        id          = 'scnet-9001'
        name        = '作业队列水位'
        status      = '进行中'
        intervalMin = 15
        priority    = 'P0'
        nextStep    = '看排队时长'
        note        = '信封形态：data.list'
        repo        = $repoRoot
    }
    [ordered]@{
        id          = 'scnet-9002'
        name        = '存储配额巡检'
        status      = '待开始'
        intervalMin = 120
        priority    = 'P2'
        nextStep    = '核对配额告警阈值'
        note        = '信封形态：data.list'
        repo        = ''
    }
)

$payload = [ordered]@{
    code    = 0
    message = 'ok'
    data    = [ordered]@{
        total = $list.Count
        list  = @($list)
    }
}

ConvertTo-Json -InputObject $payload -Depth 6
