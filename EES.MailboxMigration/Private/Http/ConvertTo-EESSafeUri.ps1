function ConvertTo-EESSafeUri {
    <#
    .SYNOPSIS
        Retire la chaîne de requête d'une URL avant journalisation.
    .DESCRIPTION
        Les URL d'import (importUrl) et les URL SAS contiennent des jetons d'accès dans la
        chaîne de requête : elles ne doivent jamais apparaître dans les logs.
    .PARAMETER Uri
        URL à nettoyer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Uri
    )

    $index = $Uri.IndexOf('?')
    if ($index -lt 0) {
        return $Uri
    }
    return $Uri.Substring(0, $index) + '?…'
}
