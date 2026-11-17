function Start-EESMailboxMigration {
    <#
    .SYNOPSIS
        Copie le contenu d'une boîte Exchange Online du tenant source vers une boîte existante du tenant cible.

    .DESCRIPTION
        Utilise les API Microsoft Graph « mailbox import/export » (copie pleine fidélité des messages,
        rendez-vous, contacts, tâches...). La boîte source n'est jamais modifiée et aucun élément de la
        boîte cible n'est supprimé.

        Dossiers :
          - Les dossiers standard (Boîte de réception, Éléments envoyés, Calendrier, Contacts...) sont
            associés à leurs équivalents dans la cible, quelle que soit la langue des deux boîtes.
          - Les dossiers personnels sont recréés avec le même chemin.
          - Avec -TargetRootFolder, toute l'arborescence est recréée sous ce dossier.

        Reprise et incrémental :
          - Un état est conservé par paire de boîtes (dossier State) : une relance reprend là où la
            précédente s'est arrêtée, sans doublon, et ne copie que les nouveautés et modifications.
          - -Incremental : passe finale juste avant la bascule MX (exige une passe complète précédente).
          - Les éléments en échec sont journalisés et retentés automatiquement à la relance suivante.

        Prérequis : Connect-EESTenant -Role Source et Connect-EESTenant -Role Target.

    .PARAMETER SourceMailbox
        Adresse (UPN) de la boîte source.

    .PARAMETER TargetMailbox
        Adresse (UPN) de la boîte cible, déjà existante et sous licence.

    .PARAMETER IncludeArchive
        Copie aussi la boîte d'archive source vers la boîte d'archive cible (qui doit être activée).
        Fonctionnalité expérimentale : l'identifiant d'archive n'est publié par Microsoft que dans
        l'API Graph beta.

    .PARAMETER TargetRootFolder
        Dossier de la boîte cible sous lequel tout est importé (ex. « Migration »). Sans ce paramètre,
        le contenu est fusionné dans les dossiers existants de la cible.

    .PARAMETER StartDate
        Ne copie que les éléments créés à partir de cette date (incluse).

    .PARAMETER EndDate
        Ne copie que les éléments créés avant cette date (exclue).

    .PARAMETER IncludeFolders
        Ne copie que ces dossiers (et leurs sous-dossiers). Accepte les noms affichés
        (« Boîte de réception/Projets ») ou indépendants de la langue (« inbox/Projets »), et les jokers.

    .PARAMETER ExcludeFolders
        Exclut ces dossiers (et leurs sous-dossiers). Même syntaxe que -IncludeFolders. Prioritaire sur
        -IncludeFolders.

    .PARAMETER Incremental
        Passe incrémentale : ne copie que les nouveautés et modifications depuis la dernière passe.
        Échoue si aucune passe complète n'a été réalisée.

    .PARAMETER Rescan
        Réénumère tous les éléments de la source au lieu d'utiliser les jetons de suivi (delta).
        Le journal évite les doublons. Utile après une modification des filtres.

    .PARAMETER BadItemLimit
        Nombre maximal d'éléments en échec avant d'arrêter la migration. -1 (défaut) : illimité,
        les échecs sont seulement journalisés.

    .PARAMETER ImportConcurrency
        Nombre d'imports simultanés dans la boîte cible (1 à 4, défaut 4 : limite Microsoft par boîte).

    .PARAMETER ProgressId
        Identifiant de la barre de progression (utilisé par Start-EESBatchMigration pour afficher
        plusieurs boîtes en parallèle). Défaut : 1.

    .EXAMPLE
        Start-EESMailboxMigration -SourceMailbox jdupont@contoso.com -TargetMailbox jean.dupont@fabrikam.com

        Copie la boîte principale.

    .EXAMPLE
        Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com -WhatIf

        Affiche le plan de correspondance des dossiers sans rien copier.

    .EXAMPLE
        Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com -TargetRootFolder 'Migration' -StartDate 2024-01-01 -ExcludeFolders 'deleteditems','junkemail'

        Copie les éléments créés depuis 2024 dans un dossier « Migration », sans les éléments supprimés ni le courrier indésirable.

    .EXAMPLE
        Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com -IncludeArchive

        Copie la boîte principale puis l'archive.

    .EXAMPLE
        Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com -Incremental

        Passe finale juste avant la bascule MX.

    .OUTPUTS
        EES.MigrationResult (un objet pour la boîte principale, un pour l'archive), ou le plan des dossiers avec -WhatIf.

    .LINK
        Connect-EESTenant
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[^@\s]+@[^@\s]+$')]
        [string]$SourceMailbox,

        [Parameter(Mandatory, Position = 1)]
        [ValidatePattern('^[^@\s]+@[^@\s]+$')]
        [string]$TargetMailbox,

        [switch]$IncludeArchive,

        [ValidateLength(1, 255)]
        [string]$TargetRootFolder,

        [datetime]$StartDate,

        [datetime]$EndDate,

        [string[]]$IncludeFolders,

        [string[]]$ExcludeFolders,

        [switch]$Incremental,

        [switch]$Rescan,

        [ValidateRange(-1, [int]::MaxValue)]
        [int]$BadItemLimit = -1,

        [ValidateRange(1, 4)]
        [int]$ImportConcurrency = 4,

        [ValidateRange(1, 100000)]
        [int]$ProgressId = 1
    )

    if ($Incremental -and $Rescan) {
        throw 'Les paramètres -Incremental et -Rescan ne peuvent pas être utilisés ensemble.'
    }
    if ($PSBoundParameters.ContainsKey('StartDate') -and $PSBoundParameters.ContainsKey('EndDate') -and $StartDate -ge $EndDate) {
        throw '-StartDate doit être antérieure à -EndDate.'
    }
    Assert-EESConnection -Role Source, Target

    # --- Résolution des boîtes ---------------------------------------------------------------------
    $pairs = [System.Collections.Generic.List[object]]::new()
    $source = Resolve-EESMailbox -Role Source -Identity $SourceMailbox
    $target = Resolve-EESMailbox -Role Target -Identity $TargetMailbox
    $pairs.Add([pscustomobject]@{ Source = $source; Target = $target; Error = $null })

    if ($IncludeArchive) {
        try {
            $sourceArchive = Resolve-EESMailbox -Role Source -Identity $SourceMailbox -Archive
            $targetArchive = Resolve-EESMailbox -Role Target -Identity $TargetMailbox -Archive
            $pairs.Add([pscustomobject]@{ Source = $sourceArchive; Target = $targetArchive; Error = $null })
            Write-EESMessage -Type Warning -Message 'Archive : fonctionnalité expérimentale (identifiant d''archive publié uniquement par l''API Graph beta).'
        }
        catch {
            $pairs.Add([pscustomobject]@{ Source = $null; Target = $null; Error = $_.Exception.Message })
            Write-EESMessage -Type Warning -Message "Archive ignorée : $($_.Exception.Message)"
        }
    }

    $description = if ($IncludeArchive) { "Copier le contenu de $SourceMailbox (boîte principale et archive)" } else { "Copier le contenu de $SourceMailbox" }

    # --- -WhatIf : plan de correspondance des dossiers ------------------------------------------
    if (-not $PSCmdlet.ShouldProcess($TargetMailbox, $description)) {
        foreach ($pair in $pairs | Where-Object { $_.Source }) {
            $sourceTree = @(Get-EESMailboxFolderTree -Role Source -Mailbox $pair.Source)
            $targetTree = @(Get-EESMailboxFolderTree -Role Target -Mailbox $pair.Target)
            $plan = @(Get-EESFolderMappingPlan -SourceFolder $sourceTree -TargetFolder $targetTree -TargetRootFolder $TargetRootFolder -IncludeFolders $IncludeFolders -ExcludeFolders $ExcludeFolders)
            $migrate = @($plan | Where-Object Status -EQ 'Migrate')
            Write-EESMessage -Type Title -Message ("Plan {0} : {1} dossier(s) à copier ({2} élément(s)), {3} exclu(s)." -f `
                    $(if ($pair.Source.IsArchive) { 'archive' } else { 'boîte principale' }), $migrate.Count,
                ($migrate | Measure-Object -Property TotalItemCount -Sum).Sum, ($plan.Count - $migrate.Count))
            foreach ($entry in $plan) {
                [pscustomobject]@{
                    PSTypeName = 'EES.FolderPlan'
                    Archive    = $pair.Source.IsArchive
                    SourcePath = $entry.SourcePath
                    TargetPath = if ($entry.Status -eq 'Migrate') { $entry.TargetPath } else { $null }
                    Items      = $entry.TotalItemCount
                    Status     = if ($entry.Status -eq 'Migrate') { 'À copier' } else { $entry.Reason }
                }
            }
        }
        return
    }

    # --- Migration --------------------------------------------------------------------------------
    $progressCounter = $ProgressId
    foreach ($pair in $pairs) {
        if (-not $pair.Source) {
            [pscustomobject]@{
                PSTypeName    = 'EES.MigrationResult'
                SourceMailbox = $SourceMailbox
                TargetMailbox = $TargetMailbox
                IsArchive     = $true
                Status        = 'Failed'
                Message       = $pair.Error
            }
            continue
        }

        $syncParams = @{
            SourceMailbox     = $pair.Source
            TargetMailbox     = $pair.Target
            TargetRootFolder  = $TargetRootFolder
            IncludeFolders    = $IncludeFolders
            ExcludeFolders    = $ExcludeFolders
            Incremental       = $Incremental
            Rescan            = $Rescan
            BadItemLimit      = $BadItemLimit
            ImportConcurrency = $ImportConcurrency
            ProgressId        = $progressCounter++
        }
        if ($PSBoundParameters.ContainsKey('StartDate')) {
            $syncParams.StartDate = $StartDate
        }
        if ($PSBoundParameters.ContainsKey('EndDate')) {
            $syncParams.EndDate = $EndDate
        }

        $result = Invoke-EESMailboxSync @syncParams

        $kind = if ($pair.Source.IsArchive) { 'Archive' } else { 'Boîte principale' }
        $summary = '{0} {1} → {2} : {3} – {4} copiés, {5} mis à jour, {6} déjà présents, {7} en échec ({8:N1} Mo, {9:hh\:mm\:ss}).' -f `
            $kind, $result.SourceMailbox, $result.TargetMailbox, $result.Status, $result.Copied, $result.Updated, $result.Skipped, $result.Failed, ($result.BytesCopied / 1MB), $result.Duration
        $type = switch ($result.Status) { 'Completed' { 'Success' } default { 'Warning' } }
        Write-EESMessage -Type $type -Message $summary
        if ($result.Message) {
            Write-EESMessage -Type Warning -Message $result.Message
        }
        $result
    }
}
