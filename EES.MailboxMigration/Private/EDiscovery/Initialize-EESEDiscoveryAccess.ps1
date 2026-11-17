function Initialize-EESEDiscoveryAccess {
    <#
    .SYNOPSIS
        Prépare l'application EES-MailboxMigration pour l'export PST eDiscovery en mode délégué.
    .DESCRIPTION
        Idempotent. Avec un compte administrateur (Administrateur général ou Administrateur de rôle
        privilégié) :
          1. Crée le service principal de l'application Microsoft « MicrosoftPurviewEDiscovery »
             (téléchargement des exports) s'il n'existe pas dans le tenant.
          2. Déclare l'application comme client public (redirection http://localhost) pour la
             connexion interactive de l'utilisateur eDiscovery.
          3. Ajoute les permissions déléguées Microsoft Graph eDiscovery.ReadWrite.All et
             MicrosoftPurviewEDiscovery eDiscovery.Download.Read.
          4. Accorde le consentement administrateur (oauth2PermissionGrants, tous les utilisateurs).
        En délégué, l'utilisateur doit en plus avoir un rôle Purview eDiscovery (eDiscovery Manager).
    .PARAMETER Config
        Configuration du tenant (Get-EESTenantConfig).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $constants = $script:EESConstants
    $adminScopes = @(
        'https://graph.microsoft.com/Application.ReadWrite.All'
        'https://graph.microsoft.com/DelegatedPermissionGrant.ReadWrite.All'
        'https://graph.microsoft.com/User.Read'
    )
    Write-EESMessage -Message "Préparation de l'export eDiscovery dans le tenant $($Config.TenantName) : connexion administrateur requise (une seule fois)."
    $admin = Connect-EESAdminAccount -TenantId $Config.TenantId -Scopes $adminScopes
    $connection = [pscustomobject]@{
        Role = 'Admin'; TenantId = $admin.TenantId; AdminAccount = $admin.Account; AdminUpn = $admin.UserPrincipalName
        AdminScopes = $adminScopes; AdminClientKey = $admin.ClientKey; ConfidentialClient = $null
    }
    $graph = @{ Connection = $connection; Delegated = $true }

    try {
        # 1. Service principals (Graph, Purview eDiscovery, application EES).
        $graphSp = Invoke-EESGraphRequest @graph -Uri ("/servicePrincipals(appId='{0}')?`$select=id,oauth2PermissionScopes" -f $constants.GraphResourceAppId)
        $purviewSp = $null
        try {
            $purviewSp = Invoke-EESGraphRequest @graph -Uri ("/servicePrincipals(appId='{0}')?`$select=id,oauth2PermissionScopes" -f $constants.PurviewEDiscoveryAppId)
        }
        catch {
            if ($_.Exception.Data['StatusCode'] -ne 404) {
                throw
            }
        }
        if (-not $purviewSp) {
            $null = Invoke-EESGraphRequest @graph -Method POST -Uri '/servicePrincipals' -Body @{ appId = $constants.PurviewEDiscoveryAppId }
            Write-EESMessage -Message 'Service principal MicrosoftPurviewEDiscovery créé dans le tenant.'
            $purviewSp = Invoke-EESWithReplicationRetry -Description 'Lecture MicrosoftPurviewEDiscovery' -ScriptBlock {
                Invoke-EESGraphRequest @graph -Uri ("/servicePrincipals(appId='{0}')?`$select=id,oauth2PermissionScopes" -f $constants.PurviewEDiscoveryAppId)
            }
        }
        $appSp = Invoke-EESGraphRequest @graph -Uri ("/servicePrincipals(appId='{0}')?`$select=id" -f $Config.AppId)
        $app = Invoke-EESGraphRequest @graph -Uri ("/applications(appId='{0}')?`$select=id,requiredResourceAccess,publicClient,isFallbackPublicClient" -f $Config.AppId)

        $graphScope = @($graphSp.oauth2PermissionScopes) | Where-Object { $_.value -eq 'eDiscovery.ReadWrite.All' } | Select-Object -First 1
        $downloadScope = @($purviewSp.oauth2PermissionScopes) | Where-Object { $_.value -eq 'eDiscovery.Download.Read' } | Select-Object -First 1
        if (-not $graphScope -or -not $downloadScope) {
            throw 'Permissions déléguées eDiscovery introuvables dans ce tenant (eDiscovery.ReadWrite.All / eDiscovery.Download.Read).'
        }

        # 2 et 3. Client public + permissions déléguées.
        $merge = Merge-EESRequiredResourceAccess -Existing @($app.requiredResourceAccess) -ResourceAppId $constants.GraphResourceAppId -RoleId @([string]$graphScope.id) -Type Scope
        $merge = Merge-EESRequiredResourceAccess -Existing @($merge.RequiredResourceAccess | ForEach-Object { [pscustomobject]$_ }) -ResourceAppId $constants.PurviewEDiscoveryAppId -RoleId @([string]$downloadScope.id) -Type Scope
        $redirects = @($app.publicClient.redirectUris)
        $patch = [ordered]@{
            requiredResourceAccess = $merge.RequiredResourceAccess
            isFallbackPublicClient = $true
            publicClient           = @{ redirectUris = @(@($redirects) + @('http://localhost') | Where-Object { $_ } | Sort-Object -Unique) }
        }
        $null = Invoke-EESGraphRequest @graph -Method PATCH -Uri "/applications/$($app.id)" -Body $patch

        # 4. Consentement administrateur (tous les utilisateurs).
        foreach ($grant in @(
                @{ ResourceId = $graphSp.id; Scope = 'eDiscovery.ReadWrite.All' }
                @{ ResourceId = $purviewSp.id; Scope = 'eDiscovery.Download.Read' }
            )) {
            $filter = "clientId eq '{0}' and resourceId eq '{1}' and consentType eq 'AllPrincipals'" -f $appSp.id, $grant.ResourceId
            $existing = @(Invoke-EESGraphRequest @graph -Uri "/oauth2PermissionGrants?`$filter=$filter" -All) | Select-Object -First 1
            if ($existing) {
                $merged = Merge-EESGrantScope -Current $existing.scope -Required $grant.Scope
                if ($merged.Changed) {
                    $null = Invoke-EESGraphRequest @graph -Method PATCH -Uri "/oauth2PermissionGrants/$($existing.id)" -Body @{ scope = $merged.Scope }
                }
            }
            else {
                $body = @{ clientId = $appSp.id; consentType = 'AllPrincipals'; resourceId = $grant.ResourceId; scope = $grant.Scope }
                $null = Invoke-EESWithReplicationRetry -Description "Consentement $($grant.Scope)" -ScriptBlock {
                    Invoke-EESGraphRequest @graph -Method POST -Uri '/oauth2PermissionGrants' -Body $body
                }
            }
            Write-EESMessage -Message "Consentement administrateur accordé : $($grant.Scope) (délégué)."
        }
    }
    catch {
        if ($_.Exception.Data['StatusCode'] -eq 403) {
            throw "Droits insuffisants pour préparer l'export eDiscovery : le compte doit être Administrateur général ou Administrateur de rôle privilégié. Détail : $($_.Exception.Message)"
        }
        throw
    }

    $Config | Add-Member -NotePropertyName 'EDiscoveryConfigured' -NotePropertyValue $true -Force
    Save-EESTenantConfig -InputObject $Config
    return $Config
}
