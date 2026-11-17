function New-EESAppCertificate {
    <#
    .SYNOPSIS
        Crée le certificat auto-signé de l'application dans Cert:\CurrentUser\My.
    .DESCRIPTION
        RSA 2048, SHA-256, clé non exportable, usage signature. Aucun secret n'est créé :
        seule la clé publique est envoyée à Entra ID.
    .PARAMETER TenantId
        GUID du tenant (inclus dans le sujet pour distinguer les certificats).
    .PARAMETER ValidityMonths
        Durée de validité.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [ValidateRange(1, 24)]
        [int]$ValidityMonths = $script:EESConstants.CertificateValidityMonths
    )

    Assert-EESPrerequisites -Require Windows

    $subject = 'CN={0}-{1}' -f $script:EESConstants.AppDisplayName, $TenantId
    if (-not $PSCmdlet.ShouldProcess('Cert:\CurrentUser\My', "Créer le certificat $subject")) {
        return
    }

    $params = @{
        Subject           = $subject
        FriendlyName      = 'EES.MailboxMigration (authentification app-only)'
        CertStoreLocation = 'Cert:\CurrentUser\My'
        KeyAlgorithm      = 'RSA'
        KeyLength         = 2048
        HashAlgorithm     = 'SHA256'
        KeySpec           = 'Signature'
        KeyExportPolicy   = 'NonExportable'
        NotAfter          = (Get-Date).AddMonths($ValidityMonths)
    }
    $certificate = New-SelfSignedCertificate @params
    Write-EESLog -Message ("Certificat créé : {0} (expire le {1:yyyy-MM-dd})" -f $certificate.Thumbprint, $certificate.NotAfter)
    return $certificate
}
