function ConvertTo-EESSafeFileName {
    <#
    .SYNOPSIS
        Transforme un texte (adresse, nom) en nom de fichier valide sur tous les systèmes.
    .PARAMETER Name
        Texte à convertir.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $invalid = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]@('<', '>', ':', '"', '/', '\', '|', '?', '*')
    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $Name.ToLowerInvariant().ToCharArray()) {
        if ($invalid -contains $character -or [char]::IsWhiteSpace($character)) {
            $null = $builder.Append('_')
        }
        else {
            $null = $builder.Append($character)
        }
    }
    return $builder.ToString()
}
