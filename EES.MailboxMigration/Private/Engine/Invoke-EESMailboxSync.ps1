function Invoke-EESMailboxSync {
    <#
    .SYNOPSIS
        Synchronise une boîte source vers une boîte cible (moteur de migration).
    .DESCRIPTION
        1. Charge l'état de la paire (journal des éléments, jetons delta, échecs).
        2. Lit les arborescences source et cible, calcule le plan de correspondance des dossiers.
        3. Relance les éléments en échec lors des passes précédentes.
        4. Pour chaque dossier : crée le dossier cible si besoin, énumère les éléments via delta
           (ou reprend depuis le dernier jeton delta), puis exporte/importe par lots.
           Les éléments déjà migrés sont ignorés, les éléments modifiés sont mis à jour.
        5. Enregistre l'état après chaque dossier : une relance reprend là où elle s'est arrêtée.
        La source n'est jamais modifiée. Aucun élément de la cible n'est supprimé.
    .PARAMETER SourceMailbox
        Boîte source résolue.
    .PARAMETER TargetMailbox
        Boîte cible résolue.
    .PARAMETER TargetRootFolder
        Dossier racine d'import dans la cible.
    .PARAMETER IncludeFolders
        Motifs des dossiers à inclure.
    .PARAMETER ExcludeFolders
        Motifs des dossiers à exclure.
    .PARAMETER StartDate
        Date de début (createdDateTime, incluse).
    .PARAMETER EndDate
        Date de fin (createdDateTime, exclue).
    .PARAMETER Incremental
        Exige une passe complète précédente.
    .PARAMETER Rescan
        Ignore les jetons delta et réénumère tous les éléments (le journal évite les doublons).
    .PARAMETER BadItemLimit
        Nombre maximal d'éléments en échec avant arrêt (-1 : illimité).
    .PARAMETER ImportConcurrency
        Imports simultanés dans la boîte cible (1 à 4).
    .PARAMETER ProgressId
        Identifiant de la barre de progression.
    .PARAMETER BufferSize
        Nombre d'éléments traités par lot export/import.
    .OUTPUTS
        Objet EES.MigrationResult.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$SourceMailbox,

        [Parameter(Mandatory)]
        [pscustomobject]$TargetMailbox,

        [string]$TargetRootFolder,

        [string[]]$IncludeFolders,

        [string[]]$ExcludeFolders,

        [Nullable[datetime]]$StartDate,

        [Nullable[datetime]]$EndDate,

        [switch]$Incremental,

        [switch]$Rescan,

        [int]$BadItemLimit = -1,

        [ValidateRange(1, 4)]
        [int]$ImportConcurrency = 4,

        [int]$ProgressId = 1,

        [ValidateRange(1, 400)]
        [int]$BufferSize = 80
    )

    $startTime = Get-Date
    $isArchive = [bool]$SourceMailbox.IsArchive
    $label = '{0} → {1}{2}' -f $SourceMailbox.Identity, $TargetMailbox.Identity, $(if ($isArchive) { ' (archive)' } else { '' })
    $context = $SourceMailbox.Identity

    $statePath = Get-EESStatePath -SourceIdentity $SourceMailbox.Identity -TargetIdentity $TargetMailbox.Identity -Archive:$isArchive
    $state = Read-EESMigrationState -Path $statePath
    if ($Incremental -and -not $state.Meta.HasCompletedRun) {
        throw "Mode incrémental impossible pour $label : aucune passe complète n'a encore été réalisée. Lancez d'abord une migration sans -Incremental."
    }
    $mode = if ($Incremental) { 'Incremental' } elseif ($state.Meta.HasCompletedRun) { 'Resume' } else { 'Full' }
    if ($Rescan) {
        $mode = 'Rescan'
    }

    $state.Meta.Runs = [int]$state.Meta.Runs + 1
    $state.Meta.LastRunStart = $startTime.ToUniversalTime().ToString('o')
    $state.Meta.SourceIdentity = $SourceMailbox.Identity
    $state.Meta.TargetIdentity = $TargetMailbox.Identity
    $state.Meta.SourceMailboxId = $SourceMailbox.MailboxId
    $state.Meta.TargetMailboxId = $TargetMailbox.MailboxId
    $state.Meta.IsArchive = $isArchive

    Write-EESLog -Context $context -Message "Début de la migration $label (mode $mode)."
    Write-Progress -Id $ProgressId -Activity $label -Status 'Analyse des dossiers source et cible...'

    $stats = @{}
    $counters = @{ Processed = 0; Total = 0 }
    $status = 'Completed'
    $message = $null
    $buffer = [System.Collections.Generic.List[object]]::new()
    $limit = $BadItemLimit
    $concurrency = $ImportConcurrency

    # Traitement d'un lot (dot-sourcé pour partager les variables locales).
    $flush = {
        if ($buffer.Count -gt 0) {
            Invoke-EESItemTransfer -SourceMailbox $SourceMailbox -TargetMailbox $TargetMailbox -State $state -Work $buffer.ToArray() -Stats $stats -ImportConcurrency $concurrency
            $counters.Processed += $buffer.Count
            $buffer.Clear()
            $failedNow = ($stats.Values | Measure-Object -Property Failed -Sum).Sum
            if ($limit -ge 0 -and $failedNow -gt $limit) {
                throw [System.OperationCanceledException]::new("Limite d'éléments en échec atteinte ($failedNow > -BadItemLimit $limit).")
            }
        }
    }
    $showProgress = {
        param([string]$folderText)
        $copied = ($stats.Values | Measure-Object -Property Copied -Sum).Sum
        $failed = ($stats.Values | Measure-Object -Property Failed -Sum).Sum
        $percent = if ($counters.Total -gt 0) { [int][math]::Min(100, 100 * $counters.Processed / $counters.Total) } else { 0 }
        Write-Progress -Id $ProgressId -Activity $label -Status ('{0} copiés, {1} en échec – {2}' -f $copied, $failed, $folderText) -PercentComplete $percent
    }

    try {
        $sourceTree = @(Get-EESMailboxFolderTree -Role Source -Mailbox $SourceMailbox)
        $targetTree = @(Get-EESMailboxFolderTree -Role Target -Mailbox $TargetMailbox)
        $planParams = @{
            SourceFolder     = $sourceTree
            TargetFolder     = $targetTree
            TargetRootFolder = $TargetRootFolder
            IncludeFolders   = $IncludeFolders
            ExcludeFolders   = $ExcludeFolders
        }
        $plan = @(Get-EESFolderMappingPlan @planParams)
        $index = ConvertTo-EESTargetFolderIndex -Folder $targetTree
        $toMigrate = @($plan | Where-Object { $_.Status -eq 'Migrate' })

        foreach ($entry in $plan) {
            $folderStat = ConvertTo-EESFolderStat -SourcePath $entry.SourcePath -TargetPath $entry.TargetPath -SourceItems $entry.TotalItemCount
            if ($entry.Status -eq 'Excluded') {
                $folderStat.Status = "Exclu ($($entry.Reason))"
            }
            $stats[$entry.SourceFolderId] = $folderStat
        }
        $counters.Total = [int](($toMigrate | Measure-Object -Property TotalItemCount -Sum).Sum)
        Write-EESLog -Context $context -Message ("{0} dossier(s) à migrer, {1} exclu(s), environ {2} élément(s)." -f $toMigrate.Count, ($plan.Count - $toMigrate.Count), $counters.Total)

        # --- 1. Relance des éléments en échec lors des passes précédentes -----------------------
        $retry = foreach ($id in @($state.Failures.Keys)) {
            $failure = $state.Failures[$id]
            $folderState = $state.Folders[[string]$failure.SourceFolderId]
            if ([int]$failure.Attempts -ge 5 -or -not $folderState -or -not $folderState.TargetFolderId) {
                continue
            }
            $journalEntry = if ($state.Items.ContainsKey($id)) { $state.Items[$id] } else { $null }
            [pscustomobject]@{
                SourceItemId    = $id
                Size            = [long]$failure.Size
                SourceFolderId  = [string]$failure.SourceFolderId
                SourcePath      = [string]$failure.FolderPath
                FolderId        = [string]$folderState.TargetFolderId
                TargetItemId    = if ($journalEntry) { $journalEntry.TargetItemId } else { $null }
                TargetChangeKey = if ($journalEntry) { $journalEntry.TargetChangeKey } else { $null }
                TargetMailboxId = if ($journalEntry) { $journalEntry.TargetMailboxId } else { $null }
            }
        }
        if (@($retry).Count -gt 0) {
            Write-EESLog -Context $context -Message "Nouvelle tentative pour $(@($retry).Count) élément(s) en échec lors des passes précédentes."
            foreach ($item in @($retry)) {
                $buffer.Add($item)
                if ($buffer.Count -ge $BufferSize) {
                    . $flush
                }
            }
            . $flush
            $counters.Processed = 0
        }

        # --- 2. Dossiers ----------------------------------------------------------------------------
        $select = '$select=id,changeKey,size,createdDateTime,type'
        $deltaHeaders = @{ Prefer = 'odata.maxpagesize=200' }
        $folderNumber = 0

        foreach ($entry in $toMigrate) {
            $folderNumber++
            $folderStat = $stats[$entry.SourceFolderId]
            $folderText = 'dossier {0}/{1} : {2}' -f $folderNumber, $toMigrate.Count, $entry.SourcePath
            & $showProgress $folderText

            $folderState = $state.Folders[$entry.SourceFolderId]
            if (-not $folderState) {
                $folderState = @{}
                $state.Folders[$entry.SourceFolderId] = $folderState
            }
            $folderState['SourcePath'] = $entry.SourcePath
            $folderState['TargetPath'] = $entry.TargetPath

            if (-not $folderState['TargetFolderId'] -or -not $index.Ids.Contains([string]$folderState['TargetFolderId'])) {
                $folderState['TargetFolderId'] = Resolve-EESTargetFolder -Mailbox $TargetMailbox -PlanEntry $entry -Index $index
            }
            $targetFolderId = [string]$folderState['TargetFolderId']

            $fullUri = "/admin/exchange/mailboxes/$($SourceMailbox.MailboxId)/folders/$($entry.SourceFolderId)/items/delta?$select"
            $savedDelta = [string]$folderState['DeltaLink']
            $uri = if (-not $Rescan -and $savedDelta) { $savedDelta } else { $fullUri }
            $restarted = $false
            $deltaLink = $null

            while ($uri) {
                try {
                    $page = Invoke-EESGraphRequest -Role Source -Uri $uri -ApiVersion $SourceMailbox.ApiVersion -Headers $deltaHeaders
                }
                catch {
                    $code = $_.Exception.Data['StatusCode']
                    if ($code -in @(400, 404, 410) -and $savedDelta -and $uri -eq $savedDelta -and -not $restarted) {
                        Write-EESLog -Level WARN -Context $context -Message "Jeton delta expiré pour « $($entry.SourcePath) » : nouvelle énumération complète (sans doublon grâce au journal)."
                        $restarted = $true
                        $uri = $fullUri
                        continue
                    }
                    throw
                }

                foreach ($item in @($page.value)) {
                    $action = Get-EESItemAction -Item $item -Journal $state.Items -StartDate $StartDate -EndDate $EndDate
                    switch ($action) {
                        'Skip' {
                            $folderStat.Skipped++
                            $counters.Processed++
                        }
                        'Filtered' {
                            $folderStat.Filtered++
                            $counters.Processed++
                        }
                        'Removed' { }
                        default {
                            $journalEntry = if ($action -eq 'Update') { $state.Items[[string]$item.id] } else { $null }
                            $buffer.Add([pscustomobject]@{
                                    SourceItemId    = [string]$item.id
                                    Size            = [long]$item.size
                                    SourceFolderId  = $entry.SourceFolderId
                                    SourcePath      = $entry.SourcePath
                                    FolderId        = $targetFolderId
                                    TargetItemId    = if ($journalEntry) { $journalEntry.TargetItemId } else { $null }
                                    TargetChangeKey = if ($journalEntry) { $journalEntry.TargetChangeKey } else { $null }
                                    TargetMailboxId = if ($journalEntry) { $journalEntry.TargetMailboxId } else { $null }
                                })
                        }
                    }
                }

                if ($buffer.Count -ge $BufferSize) {
                    . $flush
                    & $showProgress $folderText
                }

                if ($page.PSObject.Properties['@odata.nextLink'] -and $page.'@odata.nextLink') {
                    $uri = [string]$page.'@odata.nextLink'
                }
                else {
                    $deltaLink = if ($page.PSObject.Properties['@odata.deltaLink']) { [string]$page.'@odata.deltaLink' } else { $null }
                    $uri = $null
                }
            }
            . $flush

            $folderState['DeltaLink'] = $deltaLink
            $folderState['LastSync'] = (Get-Date).ToUniversalTime().ToString('o')
            $folderStat.Status = if ($folderStat.Failed -gt 0) { 'Terminé avec erreurs' } else { 'Terminé' }
            Save-EESMigrationState -State $state
            Write-EESLog -Context $context -Message ("Dossier « {0} » → « {1} » : {2} copiés, {3} mis à jour, {4} déjà migrés, {5} filtrés, {6} en échec." -f `
                    $entry.SourcePath, $entry.TargetPath, $folderStat.Copied, $folderStat.Updated, $folderStat.Skipped, $folderStat.Filtered, $folderStat.Failed)
        }

        $state.Meta.HasCompletedRun = $true
    }
    catch [System.OperationCanceledException] {
        $status = 'Stopped'
        $message = $_.Exception.Message
        Write-EESLog -Level ERROR -Context $context -Message "Migration arrêtée : $message"
    }
    catch {
        $status = 'Failed'
        $message = $_.Exception.Message
        Write-EESLog -Level ERROR -Context $context -Message "Migration en erreur : $message"
    }
    finally {
        $state.Meta.LastRunEnd = (Get-Date).ToUniversalTime().ToString('o')
        try {
            Save-EESMigrationState -State $state
        }
        catch {
            Write-EESLog -Level ERROR -Context $context -Message "Enregistrement de l'état impossible : $($_.Exception.Message)"
        }
        Write-Progress -Id $ProgressId -Activity $label -Completed
    }

    $endTime = Get-Date
    $folders = @($stats.Values | Sort-Object -Property SourcePath)
    $sum = { param($name) [long](($folders | Measure-Object -Property $name -Sum).Sum) }
    $failedCount = & $sum 'Failed'
    if ($status -eq 'Completed' -and ($failedCount -gt 0 -or $state.Failures.Count -gt 0)) {
        $status = 'CompletedWithErrors'
    }
    $bytes = & $sum 'Bytes'
    $duration = $endTime - $startTime
    $hours = [math]::Max($duration.TotalHours, 1 / 3600)

    $result = [pscustomobject]@{
        PSTypeName          = 'EES.MigrationResult'
        SourceMailbox       = $SourceMailbox.Identity
        TargetMailbox       = $TargetMailbox.Identity
        IsArchive           = $isArchive
        Mode                = $mode
        Status              = $status
        Message             = $message
        StartTime           = $startTime
        EndTime             = $endTime
        Duration            = $duration
        SourceItems         = & $sum 'SourceItems'
        Copied              = & $sum 'Copied'
        Updated             = & $sum 'Updated'
        Skipped             = & $sum 'Skipped'
        Filtered            = & $sum 'Filtered'
        Failed              = $failedCount
        PendingFailures     = $state.Failures.Count
        BytesCopied         = $bytes
        ThroughputMBPerHour = [math]::Round(($bytes / 1MB) / $hours, 1)
        Folders             = $folders
        StatePath           = $statePath
        LogFile             = $script:EESLogFile
    }

    try {
        $json = ConvertTo-Json -InputObject $result -Depth 6
        Write-EESAtomicFile -Path (Join-Path $statePath 'last-run.json') -Content $json
        [System.IO.File]::AppendAllText((Join-Path $statePath 'runs.jsonl'), (ConvertTo-Json -InputObject $result -Depth 6 -Compress) + "`n", [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-EESLog -Level WARN -Context $context -Message "Enregistrement du résultat impossible : $($_.Exception.Message)"
    }

    Write-EESLog -Context $context -Message ("Fin de la migration {0} : {1} – {2} copiés, {3} mis à jour, {4} déjà migrés, {5} en échec, {6:N1} Mo en {7:hh\:mm\:ss}." -f `
            $label, $status, $result.Copied, $result.Updated, $result.Skipped, $result.Failed, ($bytes / 1MB), $duration)
    return $result
}
