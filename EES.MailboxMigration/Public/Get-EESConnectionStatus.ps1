function Get-EESConnectionStatus {
    <#
    .SYNOPSIS
        Affiche l'état des connexions aux tenants source et cible.

    .DESCRIPTION
        Pour chaque rôle (Source, Target) : tenant, application, certificat (empreinte et expiration),
        compte administrateur éventuellement connecté et permissions effectivement accordées
        (lues dans le jeton applicatif). Les tenants configurés mais non connectés dans la session
        sont aussi listés.

    .PARAMETER Role
        Limite l'affichage à un rôle.

    .EXAMPLE
        Get-EESConnectionStatus

        Affiche l'état des deux connexions.

    .EXAMPLE
        Get-EESConnectionStatus -Role Target | Format-List

        Affiche le détail de la connexion cible.

    .OUTPUTS
        Objets EES.ConnectionStatus.

    .LINK
        Connect-EESTenant
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Source', 'Target')]
        [string]$Role
    )

    $roles = if ($Role) { @($Role) } else { @('Source', 'Target') }

    foreach ($currentRole in $roles) {
        $connection = $script:EESConnections[$currentRole]

        if (-not $connection) {
            $configs = @(Get-EESTenantConfig -Role $currentRole)
            [pscustomobject]@{
                PSTypeName            = 'EES.ConnectionStatus'
                Role                  = $currentRole
                Connected             = $false
                Status                = if ($configs.Count) { 'Non connecté (configuration disponible)' } else { 'Non configuré' }
                TenantName            = ($configs.TenantName -join ', ')
                DefaultDomain         = ($configs.DefaultDomain -join ', ')
                TenantId              = ($configs.TenantId -join ', ')
                AppId                 = ($configs.AppId -join ', ')
                CertificateThumbprint = ($configs.CertificateThumbprint -join ', ')
                CertificateExpires    = $null
                AdminAccount          = $null
                GrantedPermissions    = @()
                MissingPermissions    = @()
                WorkingDirectory      = Get-EESPath -Kind Root
            }
            continue
        }

        $granted = @()
        $missing = @()
        $status = 'Connecté (mode administrateur uniquement)'
        if ($connection.ConfidentialClient) {
            try {
                $permissions = Test-EESAppPermission -Role $currentRole
                $granted = $permissions.Granted
                $missing = $permissions.Missing
                $status = if ($permissions.IsComplete) { 'Connecté' } else { 'Connecté – permissions incomplètes (Connect-EESTenant -Repair)' }
            }
            catch {
                $status = "Erreur : $($_.Exception.Message)"
            }
        }

        [pscustomobject]@{
            PSTypeName            = 'EES.ConnectionStatus'
            Role                  = $currentRole
            Connected             = [bool]$connection.ConfidentialClient
            Status                = $status
            TenantName            = $connection.TenantName
            DefaultDomain         = $connection.DefaultDomain
            TenantId              = $connection.TenantId
            AppId                 = $connection.AppId
            CertificateThumbprint = $connection.CertificateThumbprint
            CertificateExpires    = $connection.CertificateNotAfter
            AdminAccount          = $connection.AdminUpn
            GrantedPermissions    = [string[]]$granted
            MissingPermissions    = [string[]]$missing
            WorkingDirectory      = Get-EESPath -Kind Root
        }
    }
}
