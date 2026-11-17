function Start-EESBatchMigration {
    <#
    .SYNOPSIS
        Migre en parallèle toutes les boîtes listées dans un fichier CSV.

    .DESCRIPTION
        1. Lit et valide le CSV (colonnes, adresses, dates, doublons) : aucune migration n'est lancée
           s'il contient une erreur.
        2. Vérifie que chaque boîte source et cible existe (sauf avec -SkipMailboxCheck).
        3. Lance les migrations en parallèle (-ThrottleLimit boîtes à la fois, 4 par défaut). Chaque
           boîte est traitée comme avec Start-EESMailboxMigration : reprise sans doublon, journal des
           échecs, état conservé.
        4. Affiche un récapitulatif et enregistre le résultat du lot dans le dossier Reports.

        Format du CSV : voir New-EESBatchTemplate. Les colonnes du CSV (IncludeArchive,
        TargetRootFolder, StartDate, EndDate, IncludeFolders, ExcludeFolders) s'appliquent ligne par
        ligne ; -IncludeFolders / -ExcludeFolders s'appliquent aux lignes qui n'en précisent pas.

    .PARAMETER CsvPath
        Fichier CSV du lot.

    .PARAMETER ThrottleLimit
        Nombre de boîtes migrées simultanément (1 à 20, défaut 4).

    .PARAMETER Incremental
        Passe incrémentale pour toutes les boîtes (avant la bascule MX).

    .PARAMETER Rescan
        Réénumère tous les éléments au lieu d'utiliser les jetons delta.

    .PARAMETER IncludeFolders
        Dossiers à inclure, pour les lignes qui n'ont pas de colonne IncludeFolders renseignée.

    .PARAMETER ExcludeFolders
        Dossiers à exclure, pour les lignes qui n'ont pas de colonne ExcludeFolders renseignée.

    .PARAMETER BadItemLimit
        Nombre maximal d'éléments en échec par boîte avant arrêt de cette boîte (-1 : illimité).

    .PARAMETER ImportConcurrency
        Imports simultanés par boîte cible (1 à 4).

    .PARAMETER SkipMailboxCheck
        Ne vérifie pas l'existence des boîtes avant de lancer le lot.

    .EXAMPLE
        Start-EESBatchMigration -CsvPath .\lot1.csv

        Migre les boîtes du fichier, 4 à la fois.

    .EXAMPLE
        Start-EESBatchMigration -CsvPath .\lot1.csv -WhatIf

        Valide le fichier et liste les migrations prévues sans rien copier.

    .EXAMPLE
        Start-EESBatchMigration -CsvPath .\lot1.csv -Incremental -ThrottleLimit 8

        Passe finale sur tout le lot, 8 boîtes à la fois.

    .OUTPUTS
        EES.MigrationResult (une ligne par boîte principale et par archive).

    .LINK
        New-EESBatchTemplate

    .LINK
        Test-EESMigrationReadiness

    .LINK
        Start-EESMailboxMigration
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$CsvPath,

        [ValidateRange(1, 20)]
        [int]$ThrottleLimit = 4,

        [switch]$Incremental,

        [switch]$Rescan,

        [string[]]$IncludeFolders,

        [string[]]$ExcludeFolders,

        [ValidateRange(-1, [int]::MaxValue)]
        [int]$BadItemLimit = -1,

        [ValidateRange(1, 4)]
        [int]$ImportConcurrency = 4,

        [switch]$SkipMailboxCheck
    )

    if ($Incremental -and $Rescan) {
        throw 'Les paramètres -Incremental et -Rescan ne peuvent pas être utilisés ensemble.'
    }
    Assert-EESConnection -Role Source, Target

    # --- 1. Validation du fichier ---------------------------------------------------------------
    $batch = Import-EESBatchCsv -Path $CsvPath
    foreach ($warning in $batch.Warnings) {
        Write-EESMessage -Type Warning -Message $warning
    }
    if (-not $batch.IsValid) {
        throw ("Le fichier CSV contient des erreurs, aucune migration n'a été lancée :`n - " + ($batch.Errors -join "`n - "))
    }
    $rows = @($batch.Rows)
    Write-EESMessage -Message "Fichier valide : $($rows.Count) boîte(s) à migrer (séparateur « $($batch.Delimiter) »)."

    # --- 2. Existence des boîtes ------------------------------------------------------------------
    if (-not $SkipMailboxCheck) {
        $problems = [System.Collections.Generic.List[string]]::new()
        $i = 0
        foreach ($row in $rows) {
            $i++
            Write-Progress -Id 0 -Activity 'Vérification des boîtes' -Status $row.SourceMailbox -PercentComplete ([int](100 * ($i - 1) / $rows.Count))
            foreach ($side in @(@{ Role = 'Source'; Identity = $row.SourceMailbox }, @{ Role = 'Target'; Identity = $row.TargetMailbox })) {
                try {
                    $null = Resolve-EESMailbox -Role $side.Role -Identity $side.Identity
                }
                catch {
                    $problems.Add("Ligne $($row.Line) : $($_.Exception.Message)")
                }
            }
        }
        Write-Progress -Id 0 -Activity 'Vérification des boîtes' -Completed
        if ($problems.Count -gt 0) {
            throw ("Boîtes introuvables, aucune migration n'a été lancée :`n - " + ($problems -join "`n - "))
        }
    }

    # --- -WhatIf : liste des migrations prévues ------------------------------------------------------
    if (-not $PSCmdlet.ShouldProcess("$($rows.Count) boîte(s) du fichier $CsvPath", "Migrer en parallèle ($ThrottleLimit à la fois)")) {
        foreach ($row in $rows) {
            [pscustomobject]@{
                Line             = $row.Line
                SourceMailbox    = $row.SourceMailbox
                TargetMailbox    = $row.TargetMailbox
                IncludeArchive   = $row.IncludeArchive
                TargetRootFolder = $row.TargetRootFolder
                StartDate        = $row.StartDate
                EndDate          = $row.EndDate
            }
        }
        return
    }

    # --- 3. Migration en parallèle -------------------------------------------------------------------
    Write-EESLog -Message "Début du lot $CsvPath : $($rows.Count) boîte(s), $ThrottleLimit en parallèle."
    # Les runspaces parallèles écrivent dans le même fichier de log.
    $env:EES_MAILBOXMIGRATION_LOGFILE = $script:EESLogFile

    $manifest = Join-Path -Path $script:EESModuleRoot -ChildPath 'EES.MailboxMigration.psd1'
    $sourceTenant = $script:EESConnections['Source'].TenantId
    $targetTenant = $script:EESConnections['Target'].TenantId
    $options = @{
        Incremental       = [bool]$Incremental
        Rescan            = [bool]$Rescan
        BadItemLimit      = $BadItemLimit
        ImportConcurrency = $ImportConcurrency
        IncludeFolders    = $IncludeFolders
        ExcludeFolders    = $ExcludeFolders
    }

    $work = for ($index = 0; $index -lt $rows.Count; $index++) {
        $rows[$index] | Add-Member -NotePropertyName Index -NotePropertyValue $index -Force -PassThru
    }

    $startTime = Get-Date
    $results = [System.Collections.Generic.List[object]]::new()
    $completed = 0

    $work | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $row = $_
        $options = $using:options
        $manifestPath = $using:manifest
        $sourceId = $using:sourceTenant
        $targetId = $using:targetTenant
        try {
            Import-Module -Name $manifestPath -WarningAction SilentlyContinue
            # Reconnexion non interactive (certificat) dans ce runspace.
            & (Get-Module -Name EES.MailboxMigration) {
                param($s, $t)
                $null = Restore-EESAppConnection -Role Source -Config (Get-EESTenantConfig -TenantId $s | Select-Object -First 1)
                $null = Restore-EESAppConnection -Role Target -Config (Get-EESTenantConfig -TenantId $t | Select-Object -First 1)
            } $sourceId $targetId

            $params = @{
                SourceMailbox     = $row.SourceMailbox
                TargetMailbox     = $row.TargetMailbox
                IncludeArchive    = $row.IncludeArchive
                Incremental       = $options.Incremental
                Rescan            = $options.Rescan
                BadItemLimit      = $options.BadItemLimit
                ImportConcurrency = $options.ImportConcurrency
                ProgressId        = 10 + (2 * $row.Index)
                Confirm           = $false
            }
            if ($row.TargetRootFolder) { $params.TargetRootFolder = $row.TargetRootFolder }
            if ($row.StartDate) { $params.StartDate = $row.StartDate }
            if ($row.EndDate) { $params.EndDate = $row.EndDate }
            $include = if (@($row.IncludeFolders).Count) { $row.IncludeFolders } else { $options.IncludeFolders }
            $exclude = if (@($row.ExcludeFolders).Count) { $row.ExcludeFolders } else { $options.ExcludeFolders }
            if ($include) { $params.IncludeFolders = $include }
            if ($exclude) { $params.ExcludeFolders = $exclude }

            Start-EESMailboxMigration @params
        }
        catch {
            [pscustomobject]@{
                PSTypeName    = 'EES.MigrationResult'
                SourceMailbox = $row.SourceMailbox
                TargetMailbox = $row.TargetMailbox
                IsArchive     = $false
                Status        = 'Failed'
                Message       = $_.Exception.Message
            }
        }
    } | ForEach-Object {
        $results.Add($_)
        if (-not $_.IsArchive) {
            $completed++
        }
        Write-Progress -Id 0 -Activity "Migration en lot ($($rows.Count) boîtes, $ThrottleLimit en parallèle)" `
            -Status "$completed / $($rows.Count) boîte(s) terminée(s)" -PercentComplete ([int](100 * $completed / $rows.Count))
        $_
    }
    Write-Progress -Id 0 -Activity 'Migration en lot' -Completed

    # --- 4. Récapitulatif ----------------------------------------------------------------------------
    $succeeded = @($results | Where-Object Status -EQ 'Completed').Count
    $withErrors = @($results | Where-Object Status -EQ 'CompletedWithErrors').Count
    $failed = @($results | Where-Object { $_.Status -in @('Failed', 'Stopped') }).Count
    $summaryPath = Join-Path -Path (Get-EESPath -Kind Reports) -ChildPath ('Lot_{0:yyyyMMdd_HHmmss}.json' -f $startTime)
    $summary = [ordered]@{
        CsvPath   = (Resolve-Path -LiteralPath $CsvPath).Path
        StartTime = $startTime.ToString('o')
        EndTime   = (Get-Date).ToString('o')
        Options   = $options
        Results   = $results.ToArray()
    }
    try {
        Write-EESAtomicFile -Path $summaryPath -Content (ConvertTo-Json -InputObject $summary -Depth 6)
    }
    catch {
        Write-EESLog -Level WARN -Message "Enregistrement du récapitulatif impossible : $($_.Exception.Message)"
    }

    $type = if ($failed -or $withErrors) { 'Warning' } else { 'Success' }
    Write-EESMessage -Type $type -Message ("Lot terminé en {0:hh\:mm\:ss} : {1} réussie(s), {2} avec éléments en échec, {3} en échec/arrêtée(s). Récapitulatif : {4}" -f `
        ((Get-Date) - $startTime), $succeeded, $withErrors, $failed, $summaryPath)
}
