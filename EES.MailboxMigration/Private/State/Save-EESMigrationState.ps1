function Save-EESMigrationState {
    <#
    .SYNOPSIS
        Enregistre state.json et failures.json de façon atomique (le journal items.tsv est écrit au fil de l'eau).
    .PARAMETER State
        État chargé par Read-EESMigrationState.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $document = [ordered]@{
        Meta    = $State.Meta
        Folders = $State.Folders
    }
    Write-EESAtomicFile -Path (Join-Path $State.Path 'state.json') -Content (ConvertTo-Json -InputObject $document -Depth 20)
    Write-EESAtomicFile -Path (Join-Path $State.Path 'failures.json') -Content (ConvertTo-Json -InputObject $State.Failures -Depth 10)
}
