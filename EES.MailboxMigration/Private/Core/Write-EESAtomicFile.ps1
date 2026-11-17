function Write-EESAtomicFile {
    <#
    .SYNOPSIS
        Écrit un fichier texte UTF-8 de façon atomique (fichier temporaire puis remplacement).
    .PARAMETER Path
        Fichier de destination.
    .PARAMETER Content
        Contenu texte.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $temporary = "$Path.tmp"
    [System.IO.File]::WriteAllText($temporary, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
