function ConvertTo-EESBoolean {
    <#
    .SYNOPSIS
        Convertit une valeur de CSV en booléen (fonction pure).
    .DESCRIPTION
        Vrai : true, vrai, oui, yes, o, y, 1, x. Faux : false, faux, non, no, n, 0, vide.
        Retourne $null si la valeur n'est pas reconnue.
    .PARAMETER Value
        Valeur texte.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[bool]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in @('true', 'vrai', 'oui', 'yes', 'o', 'y', '1', 'x') } { return $true }
        { $_ -in @('false', 'faux', 'non', 'no', 'n', '0') } { return $false }
    }
    return $null
}
