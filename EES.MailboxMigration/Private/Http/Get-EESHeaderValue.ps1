function Get-EESHeaderValue {
    <#
    .SYNOPSIS
        Retourne la première valeur d'un en-tête HTTP (recherche insensible à la casse).
    .PARAMETER Headers
        Dictionnaire d'en-têtes (ResponseHeadersVariable d'Invoke-RestMethod ou hashtable).
    .PARAMETER Name
        Nom de l'en-tête.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Headers,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Headers) {
        return $null
    }
    foreach ($key in $Headers.Keys) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $value = $Headers[$key]
            if ($value -is [string]) {
                return $value
            }
            return [string](@($value) | Select-Object -First 1)
        }
    }
    return $null
}
