function Test-EESFolderFilter {
    <#
    .SYNOPSIS
        Indique si un dossier correspond à l'un des motifs (fonction pure).
    .DESCRIPTION
        Chaque motif (jokers * et ? acceptés, casse ignorée) est comparé :
        - au chemin d'affichage (« Boîte de réception/Projets ») ;
        - au chemin canonique indépendant de la langue (« inbox/Projets »).
        Un motif qui désigne un dossier couvre aussi ses sous-dossiers.
        Les « \ » sont acceptés comme séparateurs, le « / » initial est ignoré.
    .PARAMETER Folder
        Dossier issu de ConvertTo-EESFolderTree.
    .PARAMETER Pattern
        Motifs.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Folder,

        [AllowEmptyCollection()]
        [string[]]$Pattern
    )

    $candidates = @($Folder.Path, $Folder.CanonicalPath) | Where-Object { $_ } | Select-Object -Unique
    foreach ($raw in @($Pattern | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $normalized = $raw.Trim().Replace('\', '/').Trim('/')
        foreach ($candidate in $candidates) {
            if ($candidate -like $normalized -or $candidate -like "$normalized/*") {
                return $true
            }
        }
    }
    return $false
}
