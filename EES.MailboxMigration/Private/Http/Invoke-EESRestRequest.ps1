function Invoke-EESRestRequest {
    <#
    .SYNOPSIS
        Envoie une requête HTTP avec reprise automatique sur erreurs transitoires.
    .DESCRIPTION
        - 429 / 502 / 503 / 504 : nouvelle tentative après le délai Retry-After (ou backoff exponentiel).
        - Erreurs réseau (timeout, connexion coupée) : nouvelle tentative avec backoff exponentiel.
        - Autres erreurs : exception explicite (voir ConvertTo-EESHttpException).
        Les URL sont nettoyées (sans chaîne de requête) avant journalisation.
    .PARAMETER Method
        Méthode HTTP.
    .PARAMETER Uri
        URL absolue.
    .PARAMETER Headers
        En-têtes HTTP (Authorization...).
    .PARAMETER Body
        Corps texte (JSON).
    .PARAMETER ContentType
        Type de contenu du corps.
    .PARAMETER MaxRetries
        Nombre maximal de nouvelles tentatives.
    .PARAMETER TimeoutSec
        Délai maximal d'une requête.
    .PARAMETER PassThru
        Retourne l'objet complet { StatusCode, Headers, Content } au lieu du seul contenu.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [hashtable]$Headers,

        [string]$Body,

        [string]$ContentType = 'application/json; charset=utf-8',

        [ValidateRange(0, 20)]
        [int]$MaxRetries = 6,

        [int]$TimeoutSec = 300,

        [switch]$PassThru
    )

    $safeUri = ConvertTo-EESSafeUri -Uri $Uri
    $attempt = 0

    while ($true) {
        $attempt++
        $sendParams = @{
            Method     = $Method
            Uri        = $Uri
            TimeoutSec = $TimeoutSec
        }
        if ($Headers) {
            $sendParams.Headers = $Headers
        }
        if ($PSBoundParameters.ContainsKey('Body')) {
            $sendParams.Body = $Body
            $sendParams.ContentType = $ContentType
        }

        try {
            $response = Send-EESHttpRequest @sendParams
        }
        catch {
            # Erreur réseau : pas de réponse HTTP exploitable.
            if ($attempt -gt $MaxRetries) {
                Write-EESLog -Level ERROR -Message ("{0} {1} : erreur réseau définitive après {2} tentatives : {3}" -f $Method, $safeUri, $attempt, $_.Exception.Message)
                throw
            }
            $delay = Get-EESRetryDelay -Attempt $attempt
            Write-EESLog -Level WARN -Message ("{0} {1} : erreur réseau ({2}). Tentative {3}/{4} dans {5:N1} s." -f $Method, $safeUri, $_.Exception.Message, $attempt, $MaxRetries, $delay)
            Start-Sleep -Milliseconds ([int]($delay * 1000))
            continue
        }

        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            if ($PassThru) {
                return $response
            }
            return $response.Content
        }

        if ((Test-EESRetryableStatusCode -StatusCode $response.StatusCode) -and $attempt -le $MaxRetries) {
            $retryAfter = Get-EESHeaderValue -Headers $response.Headers -Name 'Retry-After'
            $delay = Get-EESRetryDelay -Attempt $attempt -RetryAfter $retryAfter
            Write-EESLog -Level WARN -Message ("{0} {1} : HTTP {2}. Tentative {3}/{4} dans {5:N1} s." -f $Method, $safeUri, $response.StatusCode, $attempt, $MaxRetries, $delay)
            Start-Sleep -Milliseconds ([int]($delay * 1000))
            continue
        }

        $exception = ConvertTo-EESHttpException -Method $Method -Uri $Uri -StatusCode $response.StatusCode -Content $response.Content
        Write-EESLog -Level DEBUG -Message $exception.Message
        throw $exception
    }
}
