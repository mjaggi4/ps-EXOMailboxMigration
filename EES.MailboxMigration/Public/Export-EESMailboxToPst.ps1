function Export-EESMailboxToPst {
    <#
    .SYNOPSIS
        Exporte une boîte aux lettres Exchange Online vers un ou plusieurs fichiers PST.

    .DESCRIPTION
        Méthode EDiscovery (par défaut) : API Microsoft Purview eDiscovery de Microsoft Graph.
          - Fonctionne en mode délégué : un compte ayant le rôle Purview « eDiscovery Manager » se
            connecte de façon interactive (l'export app-only exige eDiscovery Premium).
          - Au premier usage sur un tenant, l'application EES-MailboxMigration reçoit les permissions
            déléguées eDiscovery.ReadWrite.All et eDiscovery.Download.Read (connexion administrateur).
          - Pour les licences E3 / Business, Microsoft exige un abonnement Azure « pay-as-you-go »
            relié à Purview : l'export est facturé au volume au-delà d'un quota mensuel gratuit.
          - Étapes : dossier eDiscovery, recherche sur la boîte, estimation, export PST, téléchargement
            (reprise automatique en cas de coupure), extraction des archives ZIP.

        Méthode Outlook (secours) : Outlook classique (COM) sous Windows, avec la boîte accessible
        dans le profil Outlook (accès total). Plus lente, sans coût Purview.

    .PARAMETER Mailbox
        Adresse de la boîte à exporter.

    .PARAMETER OutputPath
        Dossier de destination des fichiers PST.

    .PARAMETER Method
        EDiscovery (défaut) ou Outlook.

    .PARAMETER Role
        Tenant de la boîte : Source (défaut) ou Target. Le tenant doit avoir été connecté au moins une
        fois avec Connect-EESTenant (application EES-MailboxMigration créée).

    .PARAMETER ContentQuery
        Méthode EDiscovery uniquement : requête KQL pour limiter l'export (ex. « received>=2024-01-01 »).

    .PARAMETER NoExtract
        Méthode EDiscovery uniquement : conserve les archives ZIP sans les extraire.

    .EXAMPLE
        Export-EESMailboxToPst -Mailbox jdupont@contoso.com -OutputPath D:\PST

        Exporte la boîte via eDiscovery et télécharge les PST dans D:\PST.

    .EXAMPLE
        Export-EESMailboxToPst jdupont@contoso.com D:\PST -Method Outlook

        Exporte la boîte avec Outlook classique.

    .EXAMPLE
        Export-EESMailboxToPst jdupont@contoso.com D:\PST -ContentQuery 'received>=2023-01-01'

        N'exporte que les messages reçus depuis 2023.

    .OUTPUTS
        EES.PstExportResult

    .LINK
        Import-EESPstToMailbox
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[^@\s]+@[^@\s]+$')]
        [string]$Mailbox,

        [Parameter(Mandatory, Position = 1)]
        [string]$OutputPath,

        [ValidateSet('EDiscovery', 'Outlook')]
        [string]$Method = 'EDiscovery',

        [ValidateSet('Source', 'Target')]
        [string]$Role = 'Source',

        [string]$ContentQuery,

        [switch]$NoExtract
    )

    $output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $start = Get-Date

    if ($Method -eq 'EDiscovery') {
        $connection = $script:EESConnections[$Role]
        $config = if ($connection) {
            Get-EESTenantConfig -TenantId $connection.TenantId | Select-Object -First 1
        }
        else {
            $candidates = @(Get-EESTenantConfig -Role $Role)
            if ($candidates.Count -gt 1) {
                throw "Plusieurs tenants sont configurés pour le rôle $Role : connectez d'abord le bon tenant avec Connect-EESTenant -Role $Role."
            }
            $candidates | Select-Object -First 1
        }
        if (-not $config) {
            throw "Aucun tenant configuré pour le rôle $Role. Lancez d'abord : Connect-EESTenant -Role $Role"
        }
        $action = "Créer un dossier eDiscovery, exporter la boîte au format PST et la télécharger dans $output (pour les licences E3/Business : export facturé au volume via l'abonnement Purview pay-as-you-go)"
    }
    else {
        $action = "Exporter la boîte au format PST avec Outlook classique dans $output"
    }

    if (-not $PSCmdlet.ShouldProcess($Mailbox, $action)) {
        return
    }

    $result = [pscustomobject]@{
        PSTypeName = 'EES.PstExportResult'
        Mailbox    = $Mailbox
        Method     = $Method
        Status     = 'Failed'
        Files      = @()
        SizeGB     = 0
        ItemCount  = $null
        CaseName   = $null
        Duration   = $null
        Message    = $null
    }

    try {
        if ($Method -eq 'EDiscovery') {
            $export = Invoke-EESEDiscoveryExport -Config $config -Mailbox $Mailbox -OutputPath $output -ContentQuery $ContentQuery -NoExtract:$NoExtract
            $result.Files = @($export.Files | ForEach-Object FullName)
            $result.CaseName = $export.CaseName
            $result.ItemCount = $export.ItemCount
            $result.SizeGB = [math]::Round((($export.Downloaded | Measure-Object -Property Length -Sum).Sum) / 1GB, 2)
        }
        else {
            $file = Invoke-EESOutlookPstExport -Mailbox $Mailbox -OutputPath $output
            $result.Files = @($file.FullName)
            $result.SizeGB = [math]::Round($file.Length / 1GB, 2)
        }
        $result.Status = 'Completed'
        Write-EESMessage -Type Success -Message ("Export PST terminé : {0} fichier(s), {1} Go dans {2}" -f @($result.Files).Count, $result.SizeGB, $output)
    }
    catch {
        $message = $_.Exception.Message
        $hint = if ($Method -eq 'EDiscovery') { Get-EESEDiscoveryErrorHint -Message $message -StatusCode $_.Exception.Data['StatusCode'] } else { $null }
        $result.Message = if ($hint) { "$message`n→ $hint" } else { $message }
        Write-EESLog -Level ERROR -Message "Export PST de $Mailbox : $($result.Message)"
    }
    $result.Duration = (Get-Date) - $start
    return $result
}
