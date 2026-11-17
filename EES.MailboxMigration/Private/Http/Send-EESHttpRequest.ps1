function Send-EESHttpRequest {
    <#
    .SYNOPSIS
        Envoie une requête HTTP unique sans lever d'erreur sur les codes 4xx/5xx.
    .DESCRIPTION
        Fine enveloppe autour d'Invoke-RestMethod (isolée pour pouvoir être simulée dans les tests).
        Retourne un objet { StatusCode, Headers, Content }.
    .PARAMETER Method
        Méthode HTTP.
    .PARAMETER Uri
        URL absolue.
    .PARAMETER Headers
        En-têtes HTTP.
    .PARAMETER Body
        Corps de la requête (texte, généralement JSON).
    .PARAMETER ContentType
        Type de contenu du corps.
    .PARAMETER TimeoutSec
        Délai maximal de la requête.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [hashtable]$Headers,

        [string]$Body,

        [string]$ContentType = 'application/json; charset=utf-8',

        [int]$TimeoutSec = 300
    )

    $statusCode = 0
    $responseHeaders = $null
    $params = @{
        Method                          = $Method
        Uri                             = $Uri
        SkipHttpErrorCheck              = $true
        StatusCodeVariable              = 'statusCode'
        ResponseHeadersVariable         = 'responseHeaders'
        TimeoutSec                      = $TimeoutSec
        PreserveAuthorizationOnRedirect = $true
        ErrorAction                     = 'Stop'
    }
    if ($Headers) {
        $params.Headers = $Headers
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = $Body
        $params.ContentType = $ContentType
    }

    $content = Invoke-RestMethod @params

    return [pscustomobject]@{
        StatusCode = [int]$statusCode
        Headers    = $responseHeaders
        Content    = $content
    }
}
