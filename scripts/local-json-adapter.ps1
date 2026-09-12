# local-json-adapter.ps1
# provider=local-json 的源适配器参考实现。对应蓝皮书 Source Adapter 层（第1层）。
# 契约: list-items() / write-back() / resolve-name()，数据源 = 一个 JSON 文件（行=任务方向）。
# 这是所有 provider 里最简单的：无需凭据、无需网络，任何机器都能跑，适合 dry-run 与教学。
# 真实 provider（bitable / tencent-docs）实现同样的三个函数即可，下游调度器不动。

# 统一无 BOM UTF-8（退化写法，AGENTS.md §四；活工作站可改用 TextFile.ps1）
$script:NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-PatrolItems {
    # list-items(): 读 JSON -> PSCustomObject 数组
    param([Parameter(Mandatory)][string]$TasksFile)
    if (-not (Test-Path -LiteralPath $TasksFile)) {
        throw "Get-PatrolItems: tasks file not found: $TasksFile"
    }
    $raw = [System.IO.File]::ReadAllText($TasksFile, $script:NoBom)
    if (-not $raw.Trim()) { return @() }
    $items = $raw | ConvertFrom-Json
    return @($items)   # @ 已防止单元素解包，无需再前置逗号
}

function Save-PatrolItems {
    # write-back 的落盘：把（已被主进程回写过的）items 写回 JSON
    param([Parameter(Mandatory)][string]$TasksFile, [Parameter(Mandatory)]$Items)
    $arr = @($Items)
    $json = $arr | ConvertTo-Json -Depth 6 -AsArray
    [System.IO.File]::WriteAllText($TasksFile, $json, $script:NoBom)
}

function Resolve-ItemName {
    # resolve-name(): 给摘要用的可读名（local-json 直接取 title）
    param($Item)
    return $Item.title
}

function Set-PatrolItemFields {
    # write-back() 的单条更新便捷封装（按 id 定位、合并字段）
    param([string]$TasksFile, [string]$Id, [hashtable]$Fields)
    $items = @(Get-PatrolItems -TasksFile $TasksFile)
    foreach ($it in $items) {
        if ($it.id -eq $Id) {
            foreach ($k in $Fields.Keys) { $it.$k = $Fields[$k] }
        }
    }
    Save-PatrolItems -TasksFile $TasksFile -Items $items
}