function Get-EESPairReport {
    <#
    .SYNOPSIS
        Construit le rapport d'une paire de boîtes à partir de son dossier d'état.
    .DESCRIPTION
        Combine :
        - state.json   : métadonnées (boîtes, dates des passes) et correspondance des dossiers ;
        - items.tsv    : éléments migrés (cumul de toutes les passes), par dossier source ;
        - failures.json: éléments en échec restant à traiter ;
        - last-run.json: compteurs de la dernière passe.
        Utilisable pendant qu'une migration tourne (lecture seule).
    .PARAMETER StatePath
        Dossier d'état de la paire.
    .OUTPUTS
        { SourceMailbox, TargetMailbox, IsArchive, Status, ..., Folders, Failures, LastRun }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$StatePath
    )

    $state = Read-EESMigrationState -Path $StatePath
    $meta = $state.Meta

    $lastRun = $null
    $lastRunPath = Join-Path -Path $StatePath -ChildPath 'last-run.json'
    if (Test-Path -LiteralPath $lastRunPath) {
        try {
            $lastRun = Get-Content -LiteralPath $lastRunPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        }
        catch {
            Write-EESLog -Level WARN -Message "Résultat illisible : $lastRunPath"
        }
    }

    # Statut global.
    $start = if ($meta.LastRunStart) { [datetime]$meta.LastRunStart } else { $null }
    $end = if ($meta.LastRunEnd) { [datetime]$meta.LastRunEnd } else { $null }
    $status = if (-not $start) {
        'Jamais lancée'
    }
    elseif (-not $end -or $end -lt $start) {
        'En cours (ou interrompue)'
    }
    elseif ($lastRun) {
        switch ([string]$lastRun.Status) {
            'Completed' { 'Terminée' }
            'CompletedWithErrors' { 'Terminée avec erreurs' }
            'Stopped' { 'Arrêtée (BadItemLimit)' }
            'Failed' { 'Échec' }
            default { [string]$lastRun.Status }
        }
    }
    else {
        'Inconnue'
    }

    # Éléments migrés par dossier (cumul).
    $migratedByFolder = @{}
    foreach ($entry in $state.Items.Values) {
        $folderId = [string]$entry.SourceFolderId
        $migratedByFolder[$folderId] = [int]$migratedByFolder[$folderId] + 1
    }
    $failuresByFolder = @{}
    foreach ($failure in $state.Failures.Values) {
        $folderId = [string]$failure.SourceFolderId
        $failuresByFolder[$folderId] = [int]$failuresByFolder[$folderId] + 1
    }

    $lastFolders = @{}
    if ($lastRun -and $lastRun.Folders) {
        foreach ($f in @($lastRun.Folders)) {
            $lastFolders[[string]$f.SourcePath] = $f
        }
    }

    $folders = foreach ($folderId in $state.Folders.Keys) {
        $folderState = $state.Folders[$folderId]
        $path = [string]$folderState['SourcePath']
        $last = $lastFolders[$path]
        [pscustomobject]@{
            SourcePath      = $path
            TargetPath      = [string]$folderState['TargetPath']
            SourceItems     = if ($last) { [int]$last.SourceItems } else { $null }
            Migrated        = [int]$migratedByFolder[$folderId]
            PendingFailures = [int]$failuresByFolder[$folderId]
            LastRunCopied   = if ($last) { [int]$last.Copied } else { 0 }
            LastRunUpdated  = if ($last) { [int]$last.Updated } else { 0 }
            LastRunSkipped  = if ($last) { [int]$last.Skipped } else { 0 }
            LastRunFiltered = if ($last) { [int]$last.Filtered } else { 0 }
            LastRunFailed   = if ($last) { [int]$last.Failed } else { 0 }
            LastSync        = if ($folderState['LastSync']) { [datetime]$folderState['LastSync'] } else { $null }
        }
    }
    # Dossiers exclus (présents uniquement dans le dernier résultat).
    $known = @($folders | ForEach-Object SourcePath)
    $excluded = foreach ($path in $lastFolders.Keys) {
        if ($known -notcontains $path) {
            $last = $lastFolders[$path]
            [pscustomobject]@{
                SourcePath = $path; TargetPath = $null; SourceItems = [int]$last.SourceItems; Migrated = 0; PendingFailures = 0
                LastRunCopied = 0; LastRunUpdated = 0; LastRunSkipped = 0; LastRunFiltered = 0; LastRunFailed = 0; LastSync = $null
                Excluded = [string]$last.Status
            }
        }
    }

    $failures = foreach ($id in $state.Failures.Keys) {
        $failure = $state.Failures[$id]
        [pscustomobject]@{
            ItemId      = $id
            FolderPath  = [string]$failure.FolderPath
            SizeBytes   = [long]$failure.Size
            Error       = [string]$failure.Error
            Attempts    = [int]$failure.Attempts
            LastAttempt = [string]$failure.LastAttempt
        }
    }

    $duration = $null
    if ($lastRun -and $lastRun.Duration) {
        $duration = if ($lastRun.Duration.PSObject.Properties['Ticks']) { [TimeSpan]::FromTicks([long]$lastRun.Duration.Ticks) } else { [TimeSpan]::Parse([string]$lastRun.Duration) }
    }

    return [pscustomobject]@{
        PSTypeName          = 'EES.MigrationStatus'
        SourceMailbox       = [string]$meta.SourceIdentity
        TargetMailbox       = [string]$meta.TargetIdentity
        IsArchive           = [bool]$meta.IsArchive
        Status              = $status
        ItemsMigrated       = $state.Items.Count
        PendingFailures     = $state.Failures.Count
        Runs                = [int]$meta.Runs
        HasCompletedRun     = [bool]$meta.HasCompletedRun
        LastRunStart        = $start
        LastRunEnd          = if ($end -and $start -and $end -ge $start) { $end } else { $null }
        LastRunMode         = if ($lastRun) { [string]$lastRun.Mode } else { $null }
        LastRunCopied       = if ($lastRun) { [long]$lastRun.Copied } else { 0 }
        LastRunFailed       = if ($lastRun) { [long]$lastRun.Failed } else { 0 }
        LastRunDuration     = $duration
        LastRunMB           = if ($lastRun) { [math]::Round([long]$lastRun.BytesCopied / 1MB, 1) } else { 0 }
        ThroughputMBPerHour = if ($lastRun) { [double]$lastRun.ThroughputMBPerHour } else { 0 }
        FolderCount         = @($folders).Count
        Folders             = @(@($folders) + @($excluded) | Sort-Object -Property SourcePath)
        Failures            = @($failures)
        StatePath           = $StatePath
    }
}
