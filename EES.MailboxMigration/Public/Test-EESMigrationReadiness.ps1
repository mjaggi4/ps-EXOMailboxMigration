function Test-EESMigrationReadiness {
    <#
    .SYNOPSIS
        Vérifie, avant migration, qu'une ou plusieurs paires de boîtes sont prêtes.

    .DESCRIPTION
        Contrôles effectués :
          - permissions de l'application consenties dans les deux tenants ;
          - existence des boîtes source et cible ;
          - licence Exchange Online de la boîte cible ;
          - volume et nombre d'éléments de la source, espace libre (quota) de la cible ;
          - boîtes d'archive (si demandées) ;
          - avec -Detailed : nombre d'éléments par dossier de la source.
        Une estimation de durée est calculée sur la base d'environ 1,5 Go/h par boîte (Microsoft limite
        l'import à 150 Mo par tranche de 5 minutes et par boîte).

        Volumes et quotas proviennent du rapport Microsoft 365 « utilisation des boîtes aux lettres »
        (décalage de 24 à 48 h). Si le tenant masque les noms d'utilisateur dans les rapports, ces
        contrôles sont signalés comme non vérifiés : désactivez l'option dans le centre d'administration
        Microsoft 365 (Paramètres de l'organisation > Rapports).

    .PARAMETER SourceMailbox
        Adresse de la boîte source.

    .PARAMETER TargetMailbox
        Adresse de la boîte cible.

    .PARAMETER IncludeArchive
        Vérifie aussi les boîtes d'archive.

    .PARAMETER CsvPath
        Fichier CSV de migration en lot (voir New-EESBatchTemplate) : toutes les lignes sont vérifiées.

    .PARAMETER Detailed
        Détaille le nombre d'éléments par dossier de la source (plus long sur les grosses boîtes).

    .EXAMPLE
        Test-EESMigrationReadiness jdupont@contoso.com jean.dupont@fabrikam.com

        Vérifie une paire de boîtes.

    .EXAMPLE
        Test-EESMigrationReadiness -CsvPath .\lot1.csv | Format-Table SourceMailbox, Status, SourceSizeGB, TargetFreeGB, EstimatedDuration

        Vérifie toutes les lignes d'un CSV de lot.

    .EXAMPLE
        (Test-EESMigrationReadiness jdupont@contoso.com jean.dupont@fabrikam.com -Detailed).Checks

        Affiche le détail des contrôles.

    .OUTPUTS
        EES.ReadinessResult (une ligne par paire de boîtes).

    .LINK
        Start-EESMailboxMigration

    .LINK
        Start-EESBatchMigration
    #>
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Single', Position = 0)]
        [ValidatePattern('^[^@\s]+@[^@\s]+$')]
        [string]$SourceMailbox,

        [Parameter(Mandatory, ParameterSetName = 'Single', Position = 1)]
        [ValidatePattern('^[^@\s]+@[^@\s]+$')]
        [string]$TargetMailbox,

        [Parameter(ParameterSetName = 'Single')]
        [switch]$IncludeArchive,

        [Parameter(Mandatory, ParameterSetName = 'Csv')]
        [string]$CsvPath,

        [switch]$Detailed
    )

    Assert-EESConnection -Role Source, Target

    # --- Paires à vérifier ---------------------------------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'Csv') {
        $batch = Import-EESBatchCsv -Path $CsvPath
        foreach ($warning in $batch.Warnings) {
            Write-EESMessage -Type Warning -Message $warning
        }
        if (-not $batch.IsValid) {
            throw ("Le fichier CSV contient des erreurs :`n - " + ($batch.Errors -join "`n - "))
        }
        $pairs = @($batch.Rows | ForEach-Object { [pscustomobject]@{ Source = $_.SourceMailbox; Target = $_.TargetMailbox; Archive = $_.IncludeArchive } })
    }
    else {
        $pairs = @([pscustomobject]@{ Source = $SourceMailbox; Target = $TargetMailbox; Archive = [bool]$IncludeArchive })
    }

    # --- Contrôles communs ---------------------------------------------------------------------------
    $common = [System.Collections.Generic.List[object]]::new()
    foreach ($role in @('Source', 'Target')) {
        $label = if ($role -eq 'Source') { 'Application (source)' } else { 'Application (cible)' }
        try {
            $permissions = Test-EESAppPermission -Role $role
            if ($permissions.IsComplete) {
                $common.Add([pscustomobject]@{ Check = $label; Status = 'OK'; Detail = 'Permissions consenties' })
            }
            else {
                $common.Add([pscustomobject]@{ Check = $label; Status = 'Erreur'; Detail = "Permissions manquantes : $($permissions.Missing -join ', '). Lancez : Connect-EESTenant -Role $role -Repair" })
            }
        }
        catch {
            $common.Add([pscustomobject]@{ Check = $label; Status = 'Erreur'; Detail = $_.Exception.Message })
        }
    }

    $usage = @{ Source = $null; Target = $null }
    foreach ($role in @('Source', 'Target')) {
        try {
            $report = Get-EESMailboxUsageReport -Role $role
            $concealed = $report.Count -gt 0 -and -not ($report.Keys | Where-Object { $_ -like '*@*' } | Select-Object -First 1)
            if ($concealed) {
                $common.Add([pscustomobject]@{ Check = "Rapport d'utilisation ($role)"; Status = 'Avertissement'; Detail = 'Noms masqués dans les rapports Microsoft 365 : volumes et quotas non vérifiés.' })
            }
            else {
                $usage[$role] = $report
            }
        }
        catch {
            $common.Add([pscustomobject]@{ Check = "Rapport d'utilisation ($role)"; Status = 'Avertissement'; Detail = "Indisponible : $($_.Exception.Message)" })
        }
    }

    # --- Vérification des paires ------------------------------------------------------------------
    $results = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($pair in $pairs) {
        $index++
        Write-Progress -Id 0 -Activity 'Pré-vérifications' -Status "$($pair.Source) → $($pair.Target)" -PercentComplete ([int](100 * ($index - 1) / $pairs.Count))
        $result = Test-EESMailboxPairReadiness -SourceMailbox $pair.Source -TargetMailbox $pair.Target -IncludeArchive:$pair.Archive `
            -Detailed:$Detailed -SourceUsage $usage.Source -TargetUsage $usage.Target -CommonCheck $common.ToArray()
        $results.Add($result)
        $result
    }
    Write-Progress -Id 0 -Activity 'Pré-vérifications' -Completed

    $ready = @($results | Where-Object Status -EQ 'Prêt').Count
    $warned = @($results | Where-Object Status -EQ 'Prêt avec avertissements').Count
    $blocked = @($results | Where-Object Status -EQ 'Bloquant').Count
    $type = if ($blocked) { 'Warning' } else { 'Success' }
    Write-EESMessage -Type $type -Message "Pré-vérifications : $ready prête(s), $warned avec avertissements, $blocked bloquée(s). Problèmes : propriété Issues ; tous les contrôles : propriété Checks."
}
