function ConvertTo-EESHttpException {
    <#
    .SYNOPSIS
        Construit une exception explicite à partir d'une réponse HTTP en échec.
    .DESCRIPTION
        L'exception retournée expose dans .Data : StatusCode, ErrorCode, ErrorMessage.
        Gère le format d'erreur Graph ({ error: { code, message } }) et celui du point de
        terminaison d'import Outlook ({ Message }).
    .PARAMETER Method
        Méthode HTTP.
    .PARAMETER Uri
        URL appelée (nettoyée avant d'être incluse dans le message).
    .PARAMETER StatusCode
        Code HTTP reçu.
    .PARAMETER Content
        Corps de la réponse (objet désérialisé ou texte).
    #>
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpRequestException])]
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [int]$StatusCode,

        [AllowNull()]
        [object]$Content
    )

    $errorCode = $null
    $errorMessage = $null

    if ($Content -is [string]) {
        $errorMessage = $Content
    }
    elseif ($null -ne $Content) {
        $properties = $Content.PSObject.Properties
        if ($properties['error'] -and $null -ne $Content.error) {
            $errorCode = [string]$Content.error.code
            $errorMessage = [string]$Content.error.message
        }
        elseif ($properties['Error'] -and $null -ne $Content.Error) {
            $errorCode = [string]$Content.Error.code
            $errorMessage = [string]$Content.Error.message
        }
        elseif ($properties['Message']) {
            $errorMessage = [string]$Content.Message
        }
    }

    $text = 'Requête {0} {1} en échec (HTTP {2})' -f $Method, (ConvertTo-EESSafeUri -Uri $Uri), $StatusCode
    if ($errorCode) {
        $text += " [$errorCode]"
    }
    if ($errorMessage) {
        $text += " : $errorMessage"
    }

    $exception = [System.Net.Http.HttpRequestException]::new($text)
    $exception.Data['StatusCode'] = $StatusCode
    $exception.Data['ErrorCode'] = $errorCode
    $exception.Data['ErrorMessage'] = $errorMessage
    return $exception
}
