function Read-EESMigrationState {
    <#
    .SYNOPSIS
        Charge l'état de migration d'une paire de boîtes.
    .DESCRIPTION
        Fichiers du dossier d'état :
        - state.json    : métadonnées, correspondance des dossiers et jetons delta ;
        - items.tsv     : journal (ajout seul) des éléments migrés ; la dernière ligne d'un
                          élément fait foi. Colonnes : SourceItemId, TargetItemId,
                          SourceChangeKey, TargetChangeKey, TargetMailboxId, SourceFolderId ;
        - failures.json : éléments en échec à retenter.
    .PARAMETER Path
        Dossier d'état (Get-EESStatePath).
    .OUTPUTS
        { Path, Meta, Folders, Items, Failures }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $meta = [ordered]@{ SchemaVersion = 1; HasCompletedRun = $false; LastRunStart = $null; LastRunEnd = $null; Runs = 0 }
    $folders = @{}
    $statePath = Join-Path -Path $Path -ChildPath 'state.json'
    if (Test-Path -LiteralPath $statePath) {
        try {
            $data = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 20
        }
        catch {
            throw "Fichier d'état illisible : $statePath ($($_.Exception.Message)). Supprimez-le ou utilisez -Rescan pour repartir du journal des éléments."
        }
        if ($data.Meta) {
            foreach ($key in $data.Meta.Keys) {
                $meta[$key] = $data.Meta[$key]
            }
        }
        if ($data.Folders) {
            foreach ($key in $data.Folders.Keys) {
                $folders[$key] = $data.Folders[$key]
            }
        }
    }

    $items = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $journalPath = Join-Path -Path $Path -ChildPath 'items.tsv'
    if (Test-Path -LiteralPath $journalPath) {
        foreach ($line in [System.IO.File]::ReadLines($journalPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $columns = $line.Split("`t")
            if ($columns.Count -lt 4) {
                continue
            }
            $items[$columns[0]] = [pscustomobject]@{
                TargetItemId    = $columns[1]
                SourceChangeKey = $columns[2]
                TargetChangeKey = $columns[3]
                TargetMailboxId = if ($columns.Count -gt 4) { $columns[4] } else { $null }
                SourceFolderId  = if ($columns.Count -gt 5) { $columns[5] } else { $null }
            }
        }
    }

    $failures = @{}
    $failuresPath = Join-Path -Path $Path -ChildPath 'failures.json'
    if (Test-Path -LiteralPath $failuresPath) {
        $failureData = Get-Content -LiteralPath $failuresPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 10
        if ($failureData) {
            foreach ($key in $failureData.Keys) {
                $failures[$key] = $failureData[$key]
            }
        }
    }

    return [pscustomobject]@{
        Path     = $Path
        Meta     = $meta
        Folders  = $folders
        Items    = $items
        Failures = $failures
    }
}
