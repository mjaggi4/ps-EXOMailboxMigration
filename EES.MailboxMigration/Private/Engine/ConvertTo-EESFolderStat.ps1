function ConvertTo-EESFolderStat {
    <#
    .SYNOPSIS
        Crée l'objet de statistiques d'un dossier (compteurs à zéro).
    .PARAMETER SourcePath
        Chemin du dossier source.
    .PARAMETER TargetPath
        Chemin du dossier cible.
    .PARAMETER SourceItems
        Nombre d'éléments dans le dossier source au démarrage.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string]$SourcePath,

        [AllowEmptyString()]
        [string]$TargetPath,

        [int]$SourceItems = 0
    )

    return [pscustomobject]@{
        SourcePath  = $SourcePath
        TargetPath  = $TargetPath
        SourceItems = $SourceItems
        Copied      = 0
        Updated     = 0
        Skipped     = 0
        Filtered    = 0
        Failed      = 0
        Bytes       = [long]0
        Status      = 'Pending'
    }
}
