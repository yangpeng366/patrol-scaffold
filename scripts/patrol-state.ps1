#requires -Version 7
<#
.SYNOPSIS
  patrol-state.ps1 - Keep patrol run state outside the read-only source.

.DESCRIPTION
  Work items stay in the source (local JSON / remote table). Runtime fields
  (lastRun, currentStage, achievement, threadId) live in state/patrol-state.json.
  Writes are UTF-8 without BOM and use a temp file plus Move-Item -Force.
#>

$script:PatrolStateEncoding = [System.Text.UTF8Encoding]::new($false)
$script:PatrolStateFields = @('lastRun', 'currentStage', 'achievement', 'threadId')

function Get-PatrolStatePath {
    param([Parameter(Mandatory)][string]$BaseDir)
    $stateDir = Join-Path $BaseDir 'state'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    }
    return (Join-Path $stateDir 'patrol-state.json')
}

function Read-PatrolState {
    param([Parameter(Mandatory)][string]$Path)
    $state = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $state }

    try {
        $raw = [System.IO.File]::ReadAllText($Path, $script:PatrolStateEncoding)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }

        $parsed = $raw | ConvertFrom-Json
        foreach ($entry in @($parsed)) {
            if ($null -eq $entry) { continue }
            $id = [string]$entry.id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            $record = @{}
            foreach ($field in $script:PatrolStateFields) {
                $prop = $entry.PSObject.Properties[$field]
                $value = if ($prop) { $prop.Value } else { $null }
                # ConvertFrom-Json may turn ISO strings into DateTime; keep the
                # state file round-trip stable by storing ISO text again.
                if ($value -is [datetime]) { $value = $value.ToString('o') }
                $record[$field] = $value
            }
            $state[$id] = $record
        }
    } catch {
        Write-Warning "Read-PatrolState: failed to parse '$Path': $($_.Exception.Message)"
        return @{}
    }
    return $state
}

function Merge-PatrolState {
    param($Items, $State)
    $merged = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Items) { return }
    if ($null -eq $State) { $State = @{} }

    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $id = [string]$item.id

        if (-not [string]::IsNullOrWhiteSpace($id) -and
            ($State -is [System.Collections.IDictionary]) -and
            $State.Contains($id)) {
            $record = $State[$id]
            if ($null -ne $record) {
                foreach ($field in $script:PatrolStateFields) {
                    $value = $null
                    $present = $false
                    if ($record -is [System.Collections.IDictionary]) {
                        if ($record.Contains($field)) {
                            $present = $true
                            $value = $record[$field]
                        }
                    } else {
                        $prop = $record.PSObject.Properties[$field]
                        if ($prop) {
                            $present = $true
                            $value = $prop.Value
                        }
                    }
                    if (-not $present -or $null -eq $value) { continue }
                    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { continue }

                    if ($item -is [System.Collections.IDictionary]) {
                        $item[$field] = $value
                    } else {
                        $prop = $item.PSObject.Properties[$field]
                        if ($prop) {
                            $prop.Value = $value
                        } else {
                            $item | Add-Member -NotePropertyName $field -NotePropertyValue $value -Force
                        }
                    }
                }
            }
        }
        $merged.Add($item)
    }
    return $merged.ToArray()
}

function Save-PatrolState {
    param(
        [Parameter(Mandatory)][string]$Path,
        $Items
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $id = [string]$item.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $record = [ordered]@{ id = $id }
        foreach ($field in $script:PatrolStateFields) {
            $value = $null
            if ($item -is [System.Collections.IDictionary]) {
                if ($item.Contains($field)) { $value = $item[$field] }
            } else {
                $prop = $item.PSObject.Properties[$field]
                if ($prop) { $value = $prop.Value }
            }
            if ($value -is [datetime]) { $value = $value.ToString('o') }
            $record[$field] = $value
        }
        $records.Add([pscustomobject]$record)
    }

    $sorted = @($records | Sort-Object -Property id)
    $json = if ($sorted.Count -eq 0) { '[]' } else { $sorted | ConvertTo-Json -Depth 6 -AsArray }

    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:PatrolStateEncoding)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
