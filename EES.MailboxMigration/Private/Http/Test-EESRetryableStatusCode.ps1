function Test-EESRetryableStatusCode {
    <#
    .SYNOPSIS
        Indique si un code HTTP correspond à une erreur transitoire à réessayer.
    .DESCRIPTION
        429 (throttling), 502, 503 et 504 (indisponibilité temporaire) sont réessayés.
    .PARAMETER StatusCode
        Code HTTP reçu.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [int]$StatusCode
    )

    return $StatusCode -in @(429, 502, 503, 504)
}
