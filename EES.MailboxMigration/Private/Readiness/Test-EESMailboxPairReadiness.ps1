function Test-EESMailboxPairReadiness {
    <#
    .SYNOPSIS
        Vérifie qu'une paire de boîtes est prête à être migrée.
    .DESCRIPTION
        Contrôles : existence des boîtes source et cible, licence Exchange de la cible, volume et nombre
        d'éléments de la source, espace libre (quota) de la cible, boîtes d'archive, et facultativement
        nombre d'éléments par dossier. Chaque contrôle a le statut OK, Avertissement ou Erreur.
    .PARAMETER SourceMailbox
        Adresse de la boîte source.
    .PARAMETER TargetMailbox
        Adresse de la boîte cible.
    .PARAMETER IncludeArchive
        Vérifie les boîtes d'archive source et cible.
    .PARAMETER Detailed
        Lit l'arborescence source pour détailler le nombre d'éléments par dossier.
    .PARAMETER SourceUsage
        Rapport d'utilisation du tenant source (Get-EESMailboxUsageReport), ou $null.
    .PARAMETER TargetUsage
        Rapport d'utilisation du tenant cible, ou $null.
    .PARAMETER CommonCheck
        Contrôles communs à ajouter (permissions de l'application, disponibilité des rapports).
    .PARAMETER ThroughputGBPerHour
        Débit estimé par boîte pour le calcul de durée.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceMailbox,

        [Parameter(Mandatory)]
        [string]$TargetMailbox,

        [switch]$IncludeArchive,

        [switch]$Detailed,

        [AllowNull()]
        [hashtable]$SourceUsage,

        [AllowNull()]
        [hashtable]$TargetUsage,

        [object[]]$CommonCheck = @(),

        [double]$ThroughputGBPerHour = 1.5
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    foreach ($check in $CommonCheck) {
        $checks.Add($check)
    }
    $add = {
        param([string]$name, [ValidateSet('OK', 'Avertissement', 'Erreur')][string]$status, [string]$detail)
        $checks.Add([pscustomobject]@{ Check = $name; Status = $status; Detail = $detail })
    }

    # --- Boîtes ----------------------------------------------------------------------------------
    $source = $null
    $target = $null
    try {
        $source = Resolve-EESMailbox -Role Source -Identity $SourceMailbox
        & $add 'Boîte source' 'OK' "$($source.DisplayName) ($($source.Identity))"
    }
    catch {
        & $add 'Boîte source' 'Erreur' $_.Exception.Message
    }
    try {
        $target = Resolve-EESMailbox -Role Target -Identity $TargetMailbox
        & $add 'Boîte cible' 'OK' "$($target.DisplayName) ($($target.Identity))"
    }
    catch {
        & $add 'Boîte cible' 'Erreur' $_.Exception.Message
    }

    # --- Licence de la cible ----------------------------------------------------------------------
    if ($target) {
        try {
            $details = @(Invoke-EESGraphRequest -Role Target -Uri "/users/$($target.UserId)/licenseDetails" -All)
            $license = Test-EESExchangeLicense -LicenseDetails $details
            if ($license.HasExchange) {
                & $add 'Licence cible' 'OK' ("Exchange Online : {0}" -f ($license.Skus -join ', '))
            }
            else {
                & $add 'Licence cible' 'Erreur' 'Aucune licence Exchange Online active sur la boîte cible.'
            }
        }
        catch {
            & $add 'Licence cible' 'Avertissement' "Vérification impossible : $($_.Exception.Message)"
        }
    }

    # --- Volume et quota --------------------------------------------------------------------------
    $sourceRow = if ($source -and $SourceUsage) { $SourceUsage[$source.Identity.ToLowerInvariant()] } else { $null }
    $targetRow = if ($target -and $TargetUsage) { $TargetUsage[$target.Identity.ToLowerInvariant()] } else { $null }
    $sourceBytes = $null
    $sourceItems = $null
    $targetFree = $null

    if ($source) {
        if ($sourceRow) {
            $sourceBytes = [long]$sourceRow.'Storage Used (Byte)'
            $sourceItems = [long]$sourceRow.'Item Count'
            & $add 'Volume source' 'OK' ("{0:N2} Go, {1:N0} éléments (rapport Microsoft du {2})" -f ($sourceBytes / 1GB), $sourceItems, $sourceRow.'Report Refresh Date')
        }
        elseif ($SourceUsage) {
            & $add 'Volume source' 'Avertissement' 'Boîte absente du rapport d''utilisation (boîte récente, ou noms masqués dans les rapports Microsoft 365).'
        }
    }

    if ($target -and $targetRow) {
        $targetUsed = [long]$targetRow.'Storage Used (Byte)'
        $targetQuota = [long]$targetRow.'Prohibit Send/Receive Quota (Byte)'
        if ($targetQuota -gt 0) {
            $targetFree = $targetQuota - $targetUsed
            $detail = "{0:N2} Go libres sur {1:N2} Go" -f ($targetFree / 1GB), ($targetQuota / 1GB)
            if ($null -ne $sourceBytes -and $sourceBytes -gt $targetFree) {
                & $add 'Quota cible' 'Erreur' "Espace insuffisant : $detail pour $('{0:N2}' -f ($sourceBytes / 1GB)) Go à copier."
            }
            elseif ($null -ne $sourceBytes -and $sourceBytes -gt 0.9 * $targetFree) {
                & $add 'Quota cible' 'Avertissement' "Marge faible : $detail pour $('{0:N2}' -f ($sourceBytes / 1GB)) Go à copier."
            }
            else {
                & $add 'Quota cible' 'OK' $detail
            }
        }
    }
    elseif ($target -and $TargetUsage) {
        & $add 'Quota cible' 'Avertissement' 'Boîte cible absente du rapport d''utilisation : quota non vérifié.'
    }

    # --- Archives ---------------------------------------------------------------------------------
    if ($IncludeArchive) {
        foreach ($side in @(@{ Role = 'Source'; Identity = $SourceMailbox }, @{ Role = 'Target'; Identity = $TargetMailbox })) {
            $label = if ($side.Role -eq 'Source') { 'Archive source' } else { 'Archive cible' }
            try {
                $archive = Resolve-EESMailbox -Role $side.Role -Identity $side.Identity -Archive
                $status = if ($archive.ApiVersion -eq 'beta') { 'Avertissement' } else { 'OK' }
                & $add $label $status ("Accessible (API {0})" -f $archive.ApiVersion)
            }
            catch {
                & $add $label 'Erreur' $_.Exception.Message
            }
        }
    }
    elseif ($sourceRow -and [string]$sourceRow.'Has Archive' -eq 'True') {
        & $add 'Archive source' 'Avertissement' 'La boîte source possède une archive qui ne sera pas copiée (ajoutez -IncludeArchive ou IncludeArchive=true).'
    }

    # --- Dossiers (détail) ------------------------------------------------------------------------
    $folders = @()
    if ($Detailed -and $source) {
        try {
            $tree = @(Get-EESMailboxFolderTree -Role Source -Mailbox $source)
            $folders = @($tree | Sort-Object -Property Path | ForEach-Object {
                    [pscustomobject]@{ Path = $_.Path; Items = $_.TotalItemCount; Type = $_.Type }
                })
            $total = ($folders | Measure-Object -Property Items -Sum).Sum
            & $add 'Dossiers source' 'OK' ("{0} dossiers, {1:N0} éléments" -f $folders.Count, $total)
            if ($null -eq $sourceItems) {
                $sourceItems = $total
            }
        }
        catch {
            & $add 'Dossiers source' 'Avertissement' "Lecture impossible : $($_.Exception.Message)"
        }
    }

    $estimated = $null
    if ($null -ne $sourceBytes -and $ThroughputGBPerHour -gt 0) {
        $estimated = [TimeSpan]::FromHours(($sourceBytes / 1GB) / $ThroughputGBPerHour)
    }

    $errors = @($checks | Where-Object Status -EQ 'Erreur')
    $warnings = @($checks | Where-Object Status -EQ 'Avertissement')
    return [pscustomobject]@{
        PSTypeName        = 'EES.ReadinessResult'
        SourceMailbox     = $SourceMailbox
        TargetMailbox     = $TargetMailbox
        Ready             = ($errors.Count -eq 0)
        Status            = if ($errors.Count) { 'Bloquant' } elseif ($warnings.Count) { 'Prêt avec avertissements' } else { 'Prêt' }
        SourceSizeGB      = if ($null -ne $sourceBytes) { [math]::Round($sourceBytes / 1GB, 2) } else { $null }
        SourceItemCount   = $sourceItems
        TargetFreeGB      = if ($null -ne $targetFree) { [math]::Round($targetFree / 1GB, 2) } else { $null }
        EstimatedDuration = $estimated
        Checks            = $checks.ToArray()
        Folders           = $folders
    }
}
