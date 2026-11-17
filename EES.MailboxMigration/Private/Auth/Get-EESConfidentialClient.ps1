function Get-EESConfidentialClient {
    <#
    .SYNOPSIS
        Construit le client MSAL app-only (authentification par certificat) d'un tenant.
    .PARAMETER TenantId
        GUID du tenant.
    .PARAMETER AppId
        Identifiant (client ID) de l'application EES-MailboxMigration.
    .PARAMETER Certificate
        Certificat avec clé privée (Cert:\CurrentUser\My).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$AppId,

        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    Initialize-EESMsal

    if (-not $Certificate.HasPrivateKey) {
        throw "Le certificat $($Certificate.Thumbprint) n'a pas de clé privée accessible."
    }

    $builder = [Microsoft.Identity.Client.ConfidentialClientApplicationBuilder]::Create($AppId)
    $builder = $builder.WithTenantId($TenantId)
    $builder = $builder.WithCertificate($Certificate)
    return $builder.Build()
}
