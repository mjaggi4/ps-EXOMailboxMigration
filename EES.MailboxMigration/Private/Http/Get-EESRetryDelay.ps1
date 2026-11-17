function Get-EESRetryDelay {
    <#
    .SYNOPSIS
        Calcule le délai (en secondes) avant une nouvelle tentative HTTP.
    .DESCRIPTION
        - Si l'en-tête Retry-After est présent (nombre de secondes ou date HTTP), il est respecté.
        - Sinon : backoff exponentiel (Base * 2^(tentative-1)), plafonné, avec une gigue aléatoire
          de 0 à 1 seconde pour éviter que les threads parallèles ne réessaient en même temps.
    .PARAMETER Attempt
        Numéro de la tentative qui vient d'échouer (1 = première).
    .PARAMETER RetryAfter
        Valeur brute de l'en-tête Retry-After (peut être vide).
    .PARAMETER BaseDelaySeconds
        Délai de base du backoff exponentiel.
    .PARAMETER MaxDelaySeconds
        Plafond du backoff exponentiel.
    .PARAMETER MaxRetryAfterSeconds
        Plafond de sécurité appliqué à Retry-After.
    .PARAMETER NoJitter
        Désactive la gigue (tests).
    .PARAMETER Now
        Date de référence UTC (tests).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 1000)]
        [int]$Attempt,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RetryAfter,

        [double]$BaseDelaySeconds = 2,

        [double]$MaxDelaySeconds = 120,

        [double]$MaxRetryAfterSeconds = 900,

        [switch]$NoJitter,

        [datetime]$Now = [datetime]::UtcNow
    )

    if (-not [string]::IsNullOrWhiteSpace($RetryAfter)) {
        $value = $RetryAfter.Trim()

        # Forme 1 : nombre de secondes.
        $seconds = 0.0
        $isNumber = [double]::TryParse($value, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
        if ($isNumber) {
            return [double][math]::Min([math]::Max($seconds, 1), $MaxRetryAfterSeconds)
        }

        # Forme 2 : date HTTP (RFC 1123).
        $date = [datetimeoffset]::MinValue
        $isDate = [datetimeoffset]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)
        if ($isDate) {
            $nowUtc = if ($Now.Kind -eq [System.DateTimeKind]::Utc) { $Now } else { $Now.ToUniversalTime() }
            $delta = ($date.UtcDateTime - $nowUtc).TotalSeconds
            return [double][math]::Min([math]::Max($delta, 1), $MaxRetryAfterSeconds)
        }
    }

    $delay = $BaseDelaySeconds * [math]::Pow(2, $Attempt - 1)
    $delay = [math]::Min($delay, $MaxDelaySeconds)
    if (-not $NoJitter) {
        $delay += Get-Random -Minimum 0.0 -Maximum 1.0
    }
    return [double]$delay
}
