function ConvertTo-EESPstMappingCsv {
    <#
    .SYNOPSIS
        Produit le contenu du fichier de mappage d'import PST attendu par Microsoft Purview (fonction pure).
    .DESCRIPTION
        En-tête exact (ne pas modifier, colonnes SharePoint comprises) :
        Workload,FilePath,Name,Mailbox,IsArchive,TargetRootFolder,ContentCodePage,SPFileContainer,SPManifestContainer,SPSiteUrl
        500 lignes maximum par fichier : au-delà, plusieurs fichiers sont produits.
        TargetRootFolder : « / » fusionne dans les dossiers existants, « /Nom » importe dans un dossier,
        vide importe dans un dossier « Imported ».
    .PARAMETER Entry
        Lignes : { FilePath, Name, Mailbox, IsArchive, TargetRootFolder }.
    .PARAMETER MaxRows
        Nombre maximal de lignes par fichier.
    .OUTPUTS
        Un tableau de lignes (string[]) par fichier de mappage.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Entry,

        [ValidateRange(1, 500)]
        [int]$MaxRows = 500
    )

    $header = 'Workload,FilePath,Name,Mailbox,IsArchive,TargetRootFolder,ContentCodePage,SPFileContainer,SPManifestContainer,SPSiteUrl'
    $quote = {
        param([string]$value)
        if ($value -match '[,"]') { '"' + $value.Replace('"', '""') + '"' } else { $value }
    }

    for ($offset = 0; $offset -lt $Entry.Count; $offset += $MaxRows) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add($header)
        $last = [math]::Min($offset + $MaxRows, $Entry.Count) - 1
        foreach ($row in $Entry[$offset..$last]) {
            $archive = if ($row.IsArchive) { 'TRUE' } else { 'FALSE' }
            $lines.Add(('Exchange,{0},{1},{2},{3},{4},,,,' -f (& $quote $row.FilePath), (& $quote $row.Name), (& $quote $row.Mailbox), $archive, (& $quote $row.TargetRootFolder)))
        }
        , $lines.ToArray()
    }
}
