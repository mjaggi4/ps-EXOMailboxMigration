function Get-EESStoredCertificate {
    <#
    .SYNOPSIS
        Retourne le certificat (avec clé privée) d'empreinte donnée depuis Cert:\CurrentUser\My.
    .PARAMETER Thumbprint
        Empreinte du certificat.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Thumbprint
    )

    if ([string]::IsNullOrWhiteSpace($Thumbprint) -or -not $IsWindows) {
        return $null
    }
    $path = "Cert:\CurrentUser\My\$Thumbprint"
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $certificate = Get-Item -LiteralPath $path
    if (-not $certificate.HasPrivateKey) {
        return $null
    }
    return $certificate
}
