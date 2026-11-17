function Remove-EESTenantApp {
    <#
    .SYNOPSIS
        Supprime proprement l'application EES-MailboxMigration d'un tenant en fin de projet.

    .DESCRIPTION
        Après confirmation :
          1. Connexion interactive de l'administrateur du tenant.
          2. Suppression de l'inscription d'application (et donc de son service principal,
             de ses permissions et de son consentement), puis purge de la corbeille Entra ID.
          3. Suppression du certificat local (Cert:\CurrentUser\My), sauf avec -KeepCertificate.
          4. Suppression de la configuration locale (tenants.json) et fermeture des connexions
             liées à ce tenant.

    .PARAMETER Role
        Rôle dont le tenant est concerné (tenant connecté ou configuré pour ce rôle).

    .PARAMETER TenantId
        GUID ou domaine du tenant concerné.

    .PARAMETER KeepCertificate
        Conserve le certificat dans le magasin local.

    .PARAMETER KeepInRecycleBin
        Ne purge pas l'application de la corbeille Entra ID (restauration possible pendant 30 jours).

    .EXAMPLE
        Remove-EESTenantApp -Role Source

        Supprime l'application du tenant source après confirmation.

    .EXAMPLE
        Remove-EESTenantApp -TenantId contoso.onmicrosoft.com -WhatIf

        Affiche ce qui serait supprimé.

    .LINK
        Connect-EESTenant
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByRole')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByRole', Position = 0)]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [Parameter(Mandatory, ParameterSetName = 'ByTenant')]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [switch]$KeepCertificate,

        [switch]$KeepInRecycleBin
    )

    Assert-EESPrerequisites -Require Graph, Windows

    # --- Configuration concernée -------------------------------------------------------------
    $config = $null
    if ($PSCmdlet.ParameterSetName -eq 'ByTenant') {
        $config = Get-EESTenantConfig -TenantId $TenantId | Select-Object -First 1
    }
    else {
        $connection = $script:EESConnections[$Role]
        if ($connection) {
            $config = Get-EESTenantConfig -TenantId $connection.TenantId | Select-Object -First 1
        }
        else {
            $candidates = @(Get-EESTenantConfig -Role $Role)
            if ($candidates.Count -gt 1) {
                throw "Plusieurs tenants sont configurés pour le rôle $Role. Précisez -TenantId."
            }
            $config = $candidates | Select-Object -First 1
        }
    }
    if (-not $config) {
        throw 'Aucune application EES-MailboxMigration n''est enregistrée sur ce poste pour ce tenant.'
    }

    $target = '{0} ({1}) – AppId {2}' -f $config.TenantName, $config.TenantId, $config.AppId
    if (-not $PSCmdlet.ShouldProcess($target, "Supprimer l'application Entra ID '$($script:EESConstants.AppDisplayName)', son certificat local et sa configuration")) {
        return
    }

    Initialize-EESMsal
    $adminScopes = @(
        'https://graph.microsoft.com/Application.ReadWrite.All'
        'https://graph.microsoft.com/User.Read'
    )
    $admin = Connect-EESAdminAccount -TenantId $config.TenantId -Scopes $adminScopes
    $adminConnection = [pscustomobject]@{
        Role               = 'Admin'
        TenantId           = $admin.TenantId
        AdminAccount       = $admin.Account
        AdminUpn           = $admin.UserPrincipalName
        AdminScopes        = $adminScopes
        AdminClientKey     = $admin.ClientKey
        ConfidentialClient = $null
    }
    $graph = @{ Connection = $adminConnection; Delegated = $true }

    # --- Suppression de l'application ---------------------------------------------------------
    $app = $null
    try {
        $app = Invoke-EESGraphRequest @graph -Uri ("/applications(appId='{0}')?`$select=id,appId" -f $config.AppId)
    }
    catch {
        if ($_.Exception.Data['StatusCode'] -ne 404) {
            throw
        }
    }
    if ($app) {
        $null = Invoke-EESGraphRequest @graph -Method DELETE -Uri "/applications/$($app.id)"
        Write-EESMessage -Message "Application supprimée du tenant $($config.TenantName)."
        if (-not $KeepInRecycleBin) {
            try {
                $null = Invoke-EESWithReplicationRetry -Description 'Purge de la corbeille' -ScriptBlock {
                    Invoke-EESGraphRequest @graph -Method DELETE -Uri "/directory/deletedItems/$($app.id)"
                }
                Write-EESMessage -Message 'Application purgée de la corbeille Entra ID.'
            }
            catch {
                Write-EESMessage -Type Warning -Message "Purge de la corbeille impossible ($($_.Exception.Message)) : l'application y restera 30 jours."
            }
        }
    }
    else {
        Write-EESMessage -Type Warning -Message 'L''application n''existe plus dans le tenant (déjà supprimée).'
    }

    # --- Certificat local ------------------------------------------------------------------------
    if (-not $KeepCertificate -and $config.CertificateThumbprint) {
        $certificatePath = "Cert:\CurrentUser\My\$($config.CertificateThumbprint)"
        if (Test-Path -LiteralPath $certificatePath) {
            Remove-Item -LiteralPath $certificatePath -Confirm:$false
            Write-EESMessage -Message "Certificat local supprimé ($($config.CertificateThumbprint))."
        }
    }

    # --- Configuration et connexions -------------------------------------------------------------
    Remove-EESTenantConfig -TenantId $config.TenantId -Confirm:$false
    foreach ($currentRole in @('Source', 'Target')) {
        $existing = $script:EESConnections[$currentRole]
        if ($existing -and $existing.TenantId -eq $config.TenantId) {
            $script:EESConnections.Remove($currentRole)
        }
    }
    Clear-EESAdminClient -TenantId $config.TenantId

    Write-EESMessage -Type Success -Message "Nettoyage terminé pour le tenant $($config.TenantName)."
}
