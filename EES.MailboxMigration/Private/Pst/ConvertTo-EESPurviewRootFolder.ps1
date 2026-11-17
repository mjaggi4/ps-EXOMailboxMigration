function ConvertTo-EESPurviewRootFolder {
    <#
    .SYNOPSIS
        Convertit -TargetRootFolder en valeur de la colonne TargetRootFolder du mappage Purview (fonction pure).
    .DESCRIPTION
        - Vide ou « / » : « / » (fusion dans les dossiers existants de la boîte, comme la migration).
        - « Migration » ou « /Migration » : « /Migration ».
    .PARAMETER TargetRootFolder
        Valeur saisie.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$TargetRootFolder
    )

    $value = ([string]$TargetRootFolder).Trim().Replace('\', '/').Trim('/')
    if (-not $value) {
        return '/'
    }
    return "/$value"
}
