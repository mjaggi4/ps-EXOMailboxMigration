function Invoke-EESEDiscoveryExport {
    <#
    .SYNOPSIS
        Exporte une boîte au format PST via l'API Microsoft Purview eDiscovery (mode délégué).
    .DESCRIPTION
        1. Prépare l'application (permissions déléguées eDiscovery) au premier usage.
        2. Connexion interactive d'un utilisateur ayant le rôle eDiscovery Manager.
        3. Création d'un dossier (case) eDiscovery, d'une recherche limitée à la boîte aux lettres,
           estimation des statistiques, puis export au format PST.
        4. Téléchargement des fichiers de l'export (reprise en cas de coupure) et extraction des
           archives ZIP.
        Le dossier eDiscovery est conservé (traçabilité) ; il peut être supprimé dans le portail Purview.
    .PARAMETER Config
        Configuration du tenant.
    .PARAMETER Mailbox
        Adresse de la boîte.
    .PARAMETER OutputPath
        Dossier de destination.
    .PARAMETER ContentQuery
        Requête KQL facultative (ex. « received>=2024-01-01 »).
    .PARAMETER NoExtract
        Conserve les archives ZIP téléchargées sans les extraire.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,

        [Parameter(Mandatory)]
        [string]$Mailbox,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$ContentQuery,

        [switch]$NoExtract
    )

    $constants = $script:EESConstants
    if (-not ($Config.PSObject.Properties['EDiscoveryConfigured'] -and $Config.EDiscoveryConfigured)) {
        $Config = Initialize-EESEDiscoveryAccess -Config $Config
    }

    Write-EESMessage -Message 'Connexion du compte eDiscovery (rôle Purview « eDiscovery Manager » requis)...'
    $scopes = @('https://graph.microsoft.com/eDiscovery.ReadWrite.All')
    $user = Connect-EESAdminAccount -TenantId $Config.TenantId -Scopes $scopes -ClientId $Config.AppId
    $connection = [pscustomobject]@{
        Role = 'eDiscovery'; TenantId = $user.TenantId; AdminAccount = $user.Account; AdminUpn = $user.UserPrincipalName
        AdminScopes = $scopes; AdminClientKey = $user.ClientKey; ConfidentialClient = $null
    }
    $graph = @{ Connection = $connection; Delegated = $true }
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $caseName = "EES-Export-$Mailbox-$stamp"

    $case = Invoke-EESGraphRequest @graph -Method POST -Uri '/security/cases/ediscoveryCases' -Body @{
        displayName = $caseName
        description = "Export PST de $Mailbox par EES.MailboxMigration"
    }
    Write-EESMessage -Message "Dossier eDiscovery créé : $caseName"
    $caseUri = "/security/cases/ediscoveryCases/$($case.id)"

    $searchBody = [ordered]@{ displayName = "Recherche $Mailbox"; description = 'Contenu complet de la boîte aux lettres' }
    if ($ContentQuery) {
        $searchBody.contentQuery = $ContentQuery
    }
    $search = Invoke-EESGraphRequest @graph -Method POST -Uri "$caseUri/searches" -Body $searchBody
    $searchUri = "$caseUri/searches/$($search.id)"
    $null = Invoke-EESGraphRequest @graph -Method POST -Uri "$searchUri/additionalSources" -Body ([ordered]@{
            '@odata.type'   = 'microsoft.graph.security.userSource'
            email           = $Mailbox
            includedSources = 'mailbox'
        })

    # Estimation.
    $estimate = Invoke-EESGraphRequest @graph -Method POST -Uri "$searchUri/estimateStatistics" -PassThru
    $location = Get-EESHeaderValue -Headers $estimate.Headers -Name 'Location'
    $statistics = $null
    if ($location) {
        $statistics = Wait-EESEDiscoveryOperation -Connection $connection -OperationUri $location -Activity "Estimation du contenu de $Mailbox"
        Write-EESMessage -Message ("Estimation : {0:N0} éléments indexés ({1:N1} Mo), {2:N0} éléments non indexés ({3:N1} Mo)." -f `
                [long]$statistics.indexedItemCount, ([long]$statistics.indexedItemsSize / 1MB), [long]$statistics.unindexedItemCount, ([long]$statistics.unindexedItemsSize / 1MB))
    }

    # Export.
    $export = Invoke-EESGraphRequest @graph -Method POST -Uri "$searchUri/exportResult" -PassThru -Body ([ordered]@{
            displayName    = "Export PST $Mailbox"
            description    = 'Export PST complet (éléments indexés et partiellement indexés)'
            exportCriteria = 'searchHits, partiallyIndexed'
            exportLocation = 'responsiveLocations'
            exportFormat   = 'pst'
        })
    $exportLocation = Get-EESHeaderValue -Headers $export.Headers -Name 'Location'
    if (-not $exportLocation) {
        throw 'L''export eDiscovery a été accepté sans adresse de suivi (en-tête Location absent).'
    }
    Write-EESMessage -Message 'Export en cours de préparation par Microsoft Purview (de quelques minutes à plusieurs heures)...'
    $operation = Wait-EESEDiscoveryOperation -Connection $connection -OperationUri $exportLocation -Activity "Préparation de l'export PST de $Mailbox"

    $files = @($operation.exportFileMetadata)
    if ($files.Count -eq 0) {
        throw 'L''export est terminé mais ne contient aucun fichier à télécharger.'
    }

    # Téléchargement.
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
    }
    $downloadScope = @("$($constants.PurviewEDiscoveryAppId)/eDiscovery.Download.Read")
    # Évalué à chaque tentative de téléchargement (jeton renouvelé) ; portée dynamique : $connection, $downloadScope.
    $getHeaders = {
        $token = Get-EESAccessToken -Connection $connection -Delegated -Scopes $downloadScope
        @{ Authorization = "Bearer $token"; 'X-AllowWithAADToken' = 'true' }
    }

    $downloaded = foreach ($file in $files) {
        $target = Join-Path -Path $OutputPath -ChildPath (ConvertTo-EESSafeFileName -Name ([string]$file.fileName))
        Write-EESMessage -Message ("Téléchargement de {0} ({1:N1} Mo)..." -f $file.fileName, ([long]$file.size / 1MB))
        Save-EESDownload -Uri ([string]$file.downloadUrl) -GetHeaders $getHeaders -Path $target -ExpectedSize ([long]$file.size)
    }

    # Extraction des archives.
    $outputs = foreach ($item in @($downloaded)) {
        if ($item.Extension -eq '.zip' -and -not $NoExtract) {
            $destination = Join-Path -Path $OutputPath -ChildPath $item.BaseName
            Expand-Archive -LiteralPath $item.FullName -DestinationPath $destination -Force
            Write-EESLog -Message "Archive extraite : $destination"
            Get-ChildItem -LiteralPath $destination -Recurse -File
        }
        else {
            $item
        }
    }

    return [pscustomobject]@{
        CaseName   = $caseName
        Account    = $user.UserPrincipalName
        ItemCount  = if ($statistics) { [long]$statistics.indexedItemCount + [long]$statistics.unindexedItemCount } else { $null }
        Files      = @($outputs)
        Downloaded = @($downloaded)
    }
}
