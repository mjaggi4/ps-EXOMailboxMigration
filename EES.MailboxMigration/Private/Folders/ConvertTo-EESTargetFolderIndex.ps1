function ConvertTo-EESTargetFolderIndex {
    <#
    .SYNOPSIS
        Construit l'index des dossiers de la boîte cible (fonction pure).
    .DESCRIPTION
        - WellKnown : nom well-known -> identifiant ;
        - Children  : « parentId|nom en minuscules » -> identifiant (parentId = ROOT pour la racine) ;
        - Ids       : ensemble des identifiants connus.
    .PARAMETER Folder
        Arborescence cible (ConvertTo-EESFolderTree).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Folder
    )

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($f in $Folder) {
        $null = $ids.Add($f.Id)
    }

    $wellKnown = @{}
    $children = @{}
    foreach ($f in $Folder) {
        if ($f.WellKnownName -and -not $wellKnown.ContainsKey($f.WellKnownName)) {
            $wellKnown[$f.WellKnownName] = $f.Id
        }
        $parent = if ($f.ParentId -and $ids.Contains($f.ParentId)) { $f.ParentId } else { 'ROOT' }
        $key = '{0}|{1}' -f $parent, $f.DisplayName.ToLowerInvariant()
        if (-not $children.ContainsKey($key)) {
            $children[$key] = $f.Id
        }
    }

    return [pscustomobject]@{
        WellKnown = $wellKnown
        Children  = $children
        Ids       = $ids
    }
}
