function Add-EESItemJournal {
    <#
    .SYNOPSIS
        Ajoute des éléments migrés au journal items.tsv et à l'état en mémoire.
    .DESCRIPTION
        Écriture immédiate en ajout seul : en cas d'arrêt brutal, une relance ne recopie pas
        les éléments déjà importés.
    .PARAMETER State
        État chargé par Read-EESMigrationState.
    .PARAMETER Entry
        Éléments : { SourceItemId, TargetItemId, SourceChangeKey, TargetChangeKey, TargetMailboxId, SourceFolderId }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entry
    )

    if ($Entry.Count -eq 0) {
        return
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($item in $Entry) {
        $columns = @(
            $item.SourceItemId, $item.TargetItemId, $item.SourceChangeKey,
            $item.TargetChangeKey, $item.TargetMailboxId, $item.SourceFolderId
        ) | ForEach-Object { ([string]$_).Replace("`t", ' ').Replace("`r", '').Replace("`n", '') }
        $null = $builder.Append(($columns -join "`t")).Append("`n")

        $State.Items[[string]$item.SourceItemId] = [pscustomobject]@{
            TargetItemId    = [string]$item.TargetItemId
            SourceChangeKey = [string]$item.SourceChangeKey
            TargetChangeKey = [string]$item.TargetChangeKey
            TargetMailboxId = [string]$item.TargetMailboxId
            SourceFolderId  = [string]$item.SourceFolderId
        }
    }
    $journalPath = Join-Path -Path $State.Path -ChildPath 'items.tsv'
    [System.IO.File]::AppendAllText($journalPath, $builder.ToString(), [System.Text.UTF8Encoding]::new($false))
}
