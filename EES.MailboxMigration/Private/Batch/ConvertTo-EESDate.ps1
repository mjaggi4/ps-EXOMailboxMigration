function ConvertTo-EESDate {
    <#
    .SYNOPSIS
        Convertit une date de CSV (fonction pure).
    .DESCRIPTION
        Formats acceptés : 2025-01-31, 31/01/2025, 2025/01/31, avec heure facultative
        (2025-01-31T08:00:00, 2025-01-31 08:00, 31/01/2025 08:00). Retourne $null si invalide.
    .PARAMETER Value
        Valeur texte.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[datetime]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $formats = [string[]]@(
        'yyyy-MM-dd', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm',
        'dd/MM/yyyy', 'dd/MM/yyyy HH:mm:ss', 'dd/MM/yyyy HH:mm', 'd/M/yyyy',
        'yyyy/MM/dd', 'dd.MM.yyyy'
    )
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Value.Trim(), $formats, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)
    if ($ok) {
        return $parsed
    }
    return $null
}
