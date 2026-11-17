function Initialize-EESTenantApp {
    <#
    .SYNOPSIS
        Crée ou met à jour (de façon idempotente) l'application Entra ID EES-MailboxMigration.
    .DESCRIPTION
        Avec le jeton délégué de l'administrateur :
          1. Résout les identifiants des permissions applicatives dans Microsoft Graph.
          2. Crée l'inscription d'application, ou réutilise l'existante (par AppId enregistré, sinon par
             nom + tag) et complète ses permissions.
          3. Crée le service principal s'il n'existe pas.
          4. Crée/renouvelle le certificat auto-signé et l'ajoute à l'application, sans supprimer les
             certificats encore valides d'autres postes.
          5. Accorde le consentement administrateur par programme (appRoleAssignments sur le service
             principal Microsoft Graph).
        L'administrateur doit être Administrateur général ou Administrateur de rôle privilégié.
    .PARAMETER Connection
        Connexion portant le compte administrateur (jeton délégué).
    .PARAMETER TenantName
        Nom d'affichage du tenant.
    .PARAMETER DefaultDomain
        Domaine par défaut du tenant.
    .PARAMETER Roles
        Rôles (Source / Target) que l'application doit couvrir dans ce tenant.
    .PARAMETER ExistingConfig
        Configuration locale existante pour ce tenant (facultative).
    .PARAMETER RenewCertificate
        Force la création d'un nouveau certificat.
    .OUTPUTS
        Configuration du tenant à enregistrer dans tenants.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Connection,

        [string]$TenantName,

        [string]$DefaultDomain,

        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string[]]$Roles,

        [AllowNull()]
        [pscustomobject]$ExistingConfig,

        [switch]$RenewCertificate
    )

    $constants = $script:EESConstants
    $graph = @{ Connection = $Connection; Delegated = $true }

    try {
        # 1. Permissions requises -> identifiants d'appRoles Microsoft Graph.
        $permissionNames = Get-EESRequiredPermission -Role $Roles
        $graphSp = Invoke-EESGraphRequest @graph -Uri ("/servicePrincipals(appId='{0}')?`$select=id,appRoles" -f $constants.GraphResourceAppId)
        $roleIds = Resolve-EESGraphAppRoleId -AppRoles @($graphSp.appRoles) -PermissionName $permissionNames

        # 2. Inscription d'application.
        $app = $null
        $appSelect = '$select=id,appId,displayName,tags,requiredResourceAccess'
        if ($ExistingConfig -and $ExistingConfig.AppId) {
            try {
                $app = Invoke-EESGraphRequest @graph -Uri ("/applications(appId='{0}')?{1}" -f $ExistingConfig.AppId, $appSelect)
            }
            catch {
                if ($_.Exception.Data['StatusCode'] -ne 404) {
                    throw
                }
                Write-EESMessage -Type Warning -Message "L'application enregistrée localement ($($ExistingConfig.AppId)) n'existe plus : recherche ou recréation."
            }
        }
        if (-not $app) {
            $filter = "`$filter=displayName eq '{0}'&{1}" -f $constants.AppDisplayName, $appSelect
            $candidates = @(Invoke-EESGraphRequest @graph -Uri "/applications?$filter" -All)
            $app = $candidates | Where-Object { @($_.tags) -contains $constants.AppTag } | Select-Object -First 1
        }

        if (-not $app) {
            $merge = Merge-EESRequiredResourceAccess -Existing @() -ResourceAppId $constants.GraphResourceAppId -RoleId @($roleIds.Values)
            $body = [ordered]@{
                displayName            = $constants.AppDisplayName
                signInAudience         = 'AzureADMyOrg'
                tags                   = @($constants.AppTag)
                notes                  = 'Application créée automatiquement par le module PowerShell EES.MailboxMigration (migration de boîtes aux lettres Exchange Online). À supprimer en fin de projet avec Remove-EESTenantApp.'
                requiredResourceAccess = $merge.RequiredResourceAccess
            }
            $app = Invoke-EESGraphRequest @graph -Method POST -Uri '/applications' -Body $body
            Write-EESMessage -Message "Application $($constants.AppDisplayName) créée (AppId $($app.appId))."
        }
        else {
            $merge = Merge-EESRequiredResourceAccess -Existing @($app.requiredResourceAccess) -ResourceAppId $constants.GraphResourceAppId -RoleId @($roleIds.Values)
            if ($merge.Changed) {
                $null = Invoke-EESGraphRequest @graph -Method PATCH -Uri "/applications/$($app.id)" -Body @{ requiredResourceAccess = $merge.RequiredResourceAccess }
                Write-EESMessage -Message 'Permissions de l''application mises à jour.'
            }
            else {
                Write-EESLog -Message "Application existante réutilisée (AppId $($app.appId))."
            }
        }

        # 3. Service principal.
        $servicePrincipal = $null
        try {
            $servicePrincipal = Invoke-EESGraphRequest @graph -Uri ("/servicePrincipals(appId='{0}')?`$select=id,appId" -f $app.appId)
        }
        catch {
            if ($_.Exception.Data['StatusCode'] -ne 404) {
                throw
            }
        }
        if (-not $servicePrincipal) {
            $appId = $app.appId
            $servicePrincipal = Invoke-EESWithReplicationRetry -Description 'Création du service principal' -ScriptBlock {
                Invoke-EESGraphRequest @graph -Method POST -Uri '/servicePrincipals' -Body @{ appId = $appId }
            }
            Write-EESLog -Message "Service principal créé ($($servicePrincipal.id))."
        }

        # 4. Certificat.
        $certificate = $null
        if ($ExistingConfig -and -not $RenewCertificate) {
            $certificate = Get-EESStoredCertificate -Thumbprint $ExistingConfig.CertificateThumbprint
        }
        $renewalLimit = (Get-Date).AddDays($constants.CertificateRenewalDays)
        if (-not $certificate -or $certificate.NotAfter -lt $renewalLimit) {
            $certificate = New-EESAppCertificate -TenantId $Connection.TenantId -Confirm:$false
        }

        $keys = Invoke-EESGraphRequest @graph -Uri "/applications/$($app.id)?`$select=keyCredentials"
        $keyIdentifier = [System.Convert]::ToBase64String($certificate.GetCertHash())
        $existingKeys = @($keys.keyCredentials | Where-Object { $null -ne $_ })
        $alreadyUploaded = $existingKeys | Where-Object { $_.customKeyIdentifier -eq $keyIdentifier }
        if (-not $alreadyUploaded) {
            $now = Get-Date
            $kept = foreach ($key in $existingKeys) {
                if ($key.key -and ([datetime]$key.endDateTime) -gt $now) {
                    [ordered]@{ type = $key.type; usage = $key.usage; key = $key.key; displayName = $key.displayName }
                }
            }
            $newKey = [ordered]@{
                type        = 'AsymmetricX509Cert'
                usage       = 'Verify'
                key         = [System.Convert]::ToBase64String($certificate.RawData)
                displayName = $certificate.Subject
            }
            $null = Invoke-EESGraphRequest @graph -Method PATCH -Uri "/applications/$($app.id)" -Body @{ keyCredentials = @(@($kept) + @($newKey)) }
            Write-EESMessage -Message ("Certificat ajouté à l'application (empreinte {0}, expire le {1:dd/MM/yyyy})." -f $certificate.Thumbprint, $certificate.NotAfter)
        }

        # 5. Consentement administrateur (appRoleAssignments).
        $spId = $servicePrincipal.id
        $assignments = @(Invoke-EESGraphRequest @graph -Uri "/servicePrincipals/$spId/appRoleAssignments" -All)
        $assignedIds = @($assignments | Where-Object { $_.resourceId -eq $graphSp.id } | ForEach-Object { [string]$_.appRoleId })
        foreach ($name in $roleIds.Keys) {
            $appRoleId = $roleIds[$name]
            if ($assignedIds -contains $appRoleId) {
                continue
            }
            $assignment = @{ principalId = $spId; resourceId = $graphSp.id; appRoleId = $appRoleId }
            $null = Invoke-EESWithReplicationRetry -Description "Consentement $name" -ScriptBlock {
                Invoke-EESGraphRequest @graph -Method POST -Uri "/servicePrincipals/$($graphSp.id)/appRoleAssignedTo" -Body $assignment
            }
            Write-EESMessage -Message "Consentement administrateur accordé : $name"
        }
    }
    catch {
        $status = $_.Exception.Data['StatusCode']
        if ($status -eq 403) {
            throw ("Droits insuffisants pour configurer l'application : le compte doit être Administrateur général " +
                "ou Administrateur de rôle privilégié du tenant. Détail : $($_.Exception.Message)")
        }
        throw
    }

    $createdAt = if ($ExistingConfig -and $ExistingConfig.PSObject.Properties['CreatedAt'] -and $ExistingConfig.CreatedAt) {
        $ExistingConfig.CreatedAt
    }
    else {
        (Get-Date).ToUniversalTime().ToString('o')
    }

    return [pscustomobject]@{
        TenantId              = $Connection.TenantId
        TenantName            = $TenantName
        DefaultDomain         = $DefaultDomain
        Roles                 = [string[]]@($Roles | Sort-Object -Unique)
        AppId                 = [string]$app.appId
        AppObjectId           = [string]$app.id
        ServicePrincipalId    = [string]$spId
        CertificateThumbprint = $certificate.Thumbprint
        CertificateNotAfter   = $certificate.NotAfter.ToUniversalTime().ToString('o')
        CreatedAt             = $createdAt
    }
}
