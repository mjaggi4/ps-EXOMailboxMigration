function Restore-EESAppConnection {
    <#
    .SYNOPSIS
        Rétablit une connexion en mode application (certificat) à partir de la configuration, sans interaction.
    .DESCRIPTION
        Utilisé par Connect-EESTenant (lancements suivants) et par les traitements parallèles
        (Start-EESBatchMigration), qui ne doivent jamais ouvrir de navigateur.
        Lève une erreur si la configuration ou le certificat est absent, expiré ou proche de l'expiration.
    .PARAMETER Role
        Rôle à connecter.
    .PARAMETER Config
        Configuration du tenant (Get-EESTenantConfig).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $certificate = Get-EESStoredCertificate -Thumbprint $Config.CertificateThumbprint
    if (-not $certificate) {
        throw "Certificat de l'application introuvable sur ce poste pour le tenant $($Config.TenantName). Lancez : Connect-EESTenant -Role $Role"
    }
    if ($certificate.NotAfter -le (Get-Date).AddDays($script:EESConstants.CertificateRenewalDays)) {
        throw ("Le certificat du tenant {0} expire le {1:dd/MM/yyyy}. Lancez : Connect-EESTenant -Role {2} -RenewCertificate" -f $Config.TenantName, $certificate.NotAfter, $Role)
    }

    $connection = [pscustomobject]@{
        Role                  = $Role
        TenantId              = $Config.TenantId
        TenantName            = $Config.TenantName
        DefaultDomain         = $Config.DefaultDomain
        AppId                 = $Config.AppId
        CertificateThumbprint = $certificate.Thumbprint
        CertificateNotAfter   = $certificate.NotAfter
        ConfidentialClient    = (Get-EESConfidentialClient -TenantId $Config.TenantId -AppId $Config.AppId -Certificate $certificate)
        AdminAccount          = $null
        AdminUpn              = $null
        AdminScopes           = $null
        ConnectedAt           = Get-Date
    }
    $script:EESConnections[$Role] = $connection
    return $connection
}
