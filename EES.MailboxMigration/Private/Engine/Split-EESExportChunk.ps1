function Split-EESExportChunk {
    <#
    .SYNOPSIS
        Découpe une liste d'éléments en lots d'export (fonction pure).
    .DESCRIPTION
        exportItems accepte 20 éléments au maximum. Les lots sont aussi limités en taille cumulée
        pour éviter des réponses trop volumineuses (le flux est encodé en base64, +33 %).
        Un élément plus gros que la limite forme un lot à lui seul.
    .PARAMETER Item
        Éléments (propriétés SourceItemId et Size).
    .PARAMETER MaxItems
        Nombre maximal d'éléments par lot (20 au plus).
    .PARAMETER MaxBytes
        Taille cumulée maximale d'un lot.
    .OUTPUTS
        Tableaux d'éléments.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Item,

        [ValidateRange(1, 20)]
        [int]$MaxItems = 20,

        [long]$MaxBytes = 16MB
    )

    $chunks = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    $currentBytes = [long]0

    foreach ($entry in $Item) {
        $size = [long]$entry.Size
        $full = $current.Count -ge $MaxItems -or ($current.Count -gt 0 -and ($currentBytes + $size) -gt $MaxBytes)
        if ($full) {
            $chunks.Add($current.ToArray())
            $current = [System.Collections.Generic.List[object]]::new()
            $currentBytes = 0
        }
        $current.Add($entry)
        $currentBytes += $size
    }
    if ($current.Count -gt 0) {
        $chunks.Add($current.ToArray())
    }

    foreach ($chunk in $chunks) {
        , $chunk
    }
}
