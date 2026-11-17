function ConvertTo-EESFolderTree {
    <#
    .SYNOPSIS
        Calcule le chemin de chaque dossier à partir d'une liste à plat (fonction pure).
    .DESCRIPTION
        Pour chaque dossier :
        - Path      : chemin d'affichage (« Boîte de réception/Projets »), séparateur « / » ;
        - Segments  : noms successifs ;
        - Anchor    : nom well-known (indépendant de la langue) du plus proche ancêtre well-known
                      (le dossier lui-même compris), ou $null ;
        - Relative  : segments situés sous cet ancêtre ;
        - CanonicalPath : « inbox/Projets » si ancré, sinon Path.
        Les dossiers dont le parent n'est pas dans la liste sont à la racine de la boîte.
        Les « / » présents dans un nom de dossier sont remplacés par « ∕ » dans le chemin.
    .PARAMETER Folder
        Dossiers (id, displayName, parentFolderId, wellKnownName, type, totalItemCount).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Folder
    )

    $byId = @{}
    foreach ($f in $Folder) {
        $byId[[string]$f.id] = $f
    }

    $cache = @{}
    $resolve = $null
    $resolve = {
        param($node)
        $id = [string]$node.id
        if ($cache.ContainsKey($id)) {
            return $cache[$id]
        }
        $name = ([string]$node.displayName).Replace('/', [string][char]0x2215)
        $wellKnown = if ($node.PSObject.Properties['wellKnownName'] -and $node.wellKnownName) { ([string]$node.wellKnownName).ToLowerInvariant() } else { $null }
        $parentId = [string]$node.parentFolderId

        # Listes explicites : une expression « if » renvoyant @() produirait $null.
        $segments = [System.Collections.Generic.List[string]]::new()
        $relative = [System.Collections.Generic.List[string]]::new()
        $anchor = $wellKnown
        if ($parentId -and $byId.ContainsKey($parentId) -and $parentId -ne $id) {
            $parent = & $resolve $byId[$parentId]
            $segments.AddRange([string[]]$parent.Segments)
            if (-not $wellKnown) {
                $anchor = $parent.Anchor
                $relative.AddRange([string[]]$parent.Relative)
            }
        }
        $segments.Add($name)
        if (-not $wellKnown) {
            $relative.Add($name)
        }

        $canonical = if ($anchor) { (@($anchor) + $relative.ToArray()) -join '/' } else { $segments -join '/' }
        $result = [pscustomobject]@{
            Id             = $id
            ParentId       = $parentId
            DisplayName    = [string]$node.displayName
            WellKnownName  = $wellKnown
            Type           = if ($node.type) { [string]$node.type } else { 'IPF.Note' }
            TotalItemCount = [int]$node.totalItemCount
            Depth          = $segments.Count
            Segments       = $segments.ToArray()
            Path           = $segments -join '/'
            Anchor         = $anchor
            Relative       = $relative.ToArray()
            CanonicalPath  = $canonical
        }
        $cache[$id] = $result
        return $result
    }

    foreach ($f in $Folder) {
        & $resolve $f
    }
}
