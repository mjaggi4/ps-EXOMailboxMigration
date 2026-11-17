function Connect-EESTenant {
    <#
    .SYNOPSIS
        Connecte le module à un tenant Microsoft 365 (source ou cible) et prépare l'application de migration.

    .DESCRIPTION
        Premier lancement sur un tenant :
          1. Connexion interactive de l'administrateur (navigateur).
          2. Création automatique (ou réutilisation) de l'application Entra ID « EES-MailboxMigration » :
             inscription, service principal, permissions applicatives Microsoft Graph,
             consentement administrateur accordé par programme et certificat auto-signé
             (stocké dans Cert:\CurrentUser\My, aucun secret).
          3. Enregistrement de la configuration (sans secret) dans
             %APPDATA%\EES.MailboxMigration\tenants.json.

        Lancements suivants : la connexion se fait directement en mode application (certificat),
        sans interaction, tant que le certificat est valide et que les permissions sont complètes.

        Les tenants source et cible peuvent être connectés en même temps : chaque rôle a son propre
        contexte (aucun Connect-MgGraph global).

        Le compte administrateur doit être Administrateur général ou Administrateur de rôle privilégié
        lors de la création de l'application.

    .PARAMETER Role
        Source (tenant d'origine, lecture et export) ou Target (tenant de destination, import).

    .PARAMETER TenantId
        GUID ou domaine du tenant (ex. contoso.onmicrosoft.com). Facultatif : à défaut, le tenant
        déjà configuré pour ce rôle est utilisé, ou le tenant du compte administrateur choisi.
        Indispensable pour un administrateur partenaire (GDAP) qui se connecte au tenant d'un client.

    .PARAMETER Repair
        Force la reconnexion de l'administrateur et la vérification complète de l'application
        (permissions, consentement, certificat).

    .PARAMETER RenewCertificate
        Crée un nouveau certificat et l'ajoute à l'application.

    .PARAMETER AdminClientId
        Client public utilisé pour la connexion administrateur. Par défaut : l'application Microsoft
        « Microsoft Graph Command Line Tools ». À modifier seulement si elle est bloquée dans le tenant.

    .EXAMPLE
        Connect-EESTenant -Role Source

        Connecte le tenant source. Au premier lancement, ouvre le navigateur pour la connexion
        administrateur puis crée l'application EES-MailboxMigration.

    .EXAMPLE
        Connect-EESTenant -Role Target -TenantId fabrikam.onmicrosoft.com

        Connecte le tenant cible en précisant son domaine.

    .EXAMPLE
        Connect-EESTenant -Role Source -WhatIf

        Affiche ce qui serait créé dans le tenant sans rien modifier.

    .EXAMPLE
        Connect-EESTenant -Role Target -Repair

        Revérifie l'application (permissions, consentement, certificat) avec un compte administrateur.

    .OUTPUTS
        État de la connexion (voir Get-EESConnectionStatus).

    .LINK
        Get-EESConnectionStatus

    .LINK
        Disconnect-EESTenant

    .LINK
        Remove-EESTenantApp
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [switch]$Repair,

        [switch]$RenewCertificate,

        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$AdminClientId = $script:EESConstants.AdminClientId
    )

    Assert-EESPrerequisites -Require Graph, Windows
    Initialize-EESMsal
    $constants = $script:EESConstants

    # --- 1. Configuration locale existante ---------------------------------------------------
    $config = $null
    if ($TenantId) {
        $config = Get-EESTenantConfig -TenantId $TenantId | Select-Object -First 1
    }
    else {
        $candidates = @(Get-EESTenantConfig -Role $Role)
        if ($candidates.Count -eq 1) {
            $config = $candidates[0]
        }
        elseif ($candidates.Count -gt 1) {
            $list = ($candidates | ForEach-Object { "$($_.TenantName) ($($_.DefaultDomain))" }) -join ', '
            Write-EESMessage -Type Warning -Message "Plusieurs tenants sont configurés pour le rôle $Role : $list. Précisez -TenantId pour éviter la connexion interactive."
        }
    }

    # --- 2. Connexion directe en mode application (certificat) -----------------------------
    if ($config -and -not $Repair -and -not $RenewCertificate -and @($config.Roles) -contains $Role) {
        $certificate = Get-EESStoredCertificate -Thumbprint $config.CertificateThumbprint
        $renewalLimit = (Get-Date).AddDays($constants.CertificateRenewalDays)
        if ($certificate -and $certificate.NotAfter -gt $renewalLimit) {
            $null = Restore-EESAppConnection -Role $Role -Config $config
            try {
                $permissions = Test-EESAppPermission -Role $Role
                if ($permissions.IsComplete) {
                    Write-EESMessage -Type Success -Message "Tenant $Role connecté : $($config.TenantName) ($($config.DefaultDomain)) – mode application."
                    return Get-EESConnectionStatus -Role $Role
                }
                Write-EESMessage -Type Warning -Message "Permissions manquantes : $($permissions.Missing -join ', '). Une connexion administrateur est nécessaire pour les accorder."
            }
            catch {
                Write-EESMessage -Type Warning -Message "Connexion en mode application impossible ($($_.Exception.Message)). Une connexion administrateur est nécessaire."
            }
            $script:EESConnections.Remove($Role)
        }
        elseif ($certificate) {
            Write-EESMessage -Type Warning -Message ("Le certificat expire le {0:dd/MM/yyyy} : il va être renouvelé." -f $certificate.NotAfter)
        }
        else {
            Write-EESMessage -Type Warning -Message "Le certificat de l'application est introuvable sur ce poste : un nouveau certificat va être créé."
        }
    }

    # --- 3. Connexion administrateur (déléguée) ----------------------------------------------
    $adminScopes = @(
        'https://graph.microsoft.com/Application.ReadWrite.All'
        'https://graph.microsoft.com/AppRoleAssignment.ReadWrite.All'
        'https://graph.microsoft.com/Organization.Read.All'
        'https://graph.microsoft.com/User.Read'
    )
    $authorityTenant = if ($TenantId) { $TenantId } elseif ($config) { $config.TenantId } else { 'organizations' }
    $admin = Connect-EESAdminAccount -TenantId $authorityTenant -Scopes $adminScopes -ClientId $AdminClientId

    if (-not $config -or $config.TenantId -ne $admin.TenantId) {
        $config = Get-EESTenantConfig -TenantId $admin.TenantId | Select-Object -First 1
    }

    $connection = [pscustomobject]@{
        Role                  = $Role
        TenantId              = $admin.TenantId
        TenantName            = $null
        DefaultDomain         = $null
        AppId                 = if ($config) { $config.AppId } else { $null }
        CertificateThumbprint = $null
        CertificateNotAfter   = $null
        ConfidentialClient    = $null
        AdminAccount          = $admin.Account
        AdminUpn              = $admin.UserPrincipalName
        AdminScopes           = $adminScopes
        AdminClientKey        = $admin.ClientKey
        ConnectedAt           = Get-Date
    }
    $script:EESConnections[$Role] = $connection

    $organization = @((Invoke-EESGraphRequest -Connection $connection -Delegated -Uri '/organization?$select=id,displayName,verifiedDomains').value) | Select-Object -First 1
    $connection.TenantName = $organization.displayName
    $connection.DefaultDomain = (@($organization.verifiedDomains) | Where-Object { $_.isDefault } | Select-Object -First 1).name

    $otherRole = if ($Role -eq 'Source') { 'Target' } else { 'Source' }
    $other = $script:EESConnections[$otherRole]
    if ($other -and $other.TenantId -eq $connection.TenantId) {
        Write-EESMessage -Type Warning -Message "Attention : les tenants source et cible sont identiques ($($connection.TenantName))."
    }

    # --- 4. Création / mise à jour de l'application ------------------------------------------
    $roles = @(@($config.Roles) + @($Role) | Where-Object { $_ } | Sort-Object -Unique)
    $permissionList = (Get-EESRequiredPermission -Role $roles) -join ', '
    $target = '{0} ({1})' -f $connection.TenantName, $connection.DefaultDomain
    $action = "Créer ou mettre à jour l'application Entra ID '$($constants.AppDisplayName)' (permissions : $permissionList), son certificat et le consentement administrateur"

    if (-not $PSCmdlet.ShouldProcess($target, $action)) {
        Write-EESMessage -Type Warning -Message "Aucune modification effectuée. Le tenant $Role reste connecté uniquement en mode administrateur."
        return Get-EESConnectionStatus -Role $Role
    }

    $tenantConfig = Initialize-EESTenantApp -Connection $connection -TenantName $connection.TenantName -DefaultDomain $connection.DefaultDomain `
        -Roles $roles -ExistingConfig $config -RenewCertificate:$RenewCertificate
    Save-EESTenantConfig -InputObject $tenantConfig

    $certificate = Get-EESStoredCertificate -Thumbprint $tenantConfig.CertificateThumbprint
    $connection.AppId = $tenantConfig.AppId
    $connection.CertificateThumbprint = $certificate.Thumbprint
    $connection.CertificateNotAfter = $certificate.NotAfter
    $connection.ConfidentialClient = Get-EESConfidentialClient -TenantId $tenantConfig.TenantId -AppId $tenantConfig.AppId -Certificate $certificate

    Write-EESMessage -Message 'Vérification de la propagation des permissions dans Entra ID (jusqu''à 5 minutes)...'
    $null = Wait-EESAppPermission -Role $Role -Required (Get-EESRequiredPermission -Role $roles)

    Write-EESMessage -Type Success -Message "Tenant $Role connecté : $($connection.TenantName) ($($connection.DefaultDomain))."
    return Get-EESConnectionStatus -Role $Role
}
