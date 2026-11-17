function Get-EESFolderMappingPlan {
    <#
    .SYNOPSIS
        Calcule le plan de correspondance des dossiers source -> cible (fonction pure).
    .DESCRIPTION
        Règles :
        - Sans -TargetRootFolder : un dossier well-known de la source (inbox, sentitems, calendar...)
          est associé au dossier de même nom well-known de la cible, quelle que soit la langue des
          deux boîtes ; ses sous-dossiers sont recréés sous ce dossier. Les dossiers personnalisés
          sont recréés par chemin depuis la racine.
        - Avec -TargetRootFolder « Migration » : toute l'arborescence source est recréée sous
          « Migration » (noms d'affichage de la source).
        - Les dossiers système non migrables (dossiers de recherche, problèmes de synchronisation,
          boîte d'envoi...) et leurs sous-dossiers sont toujours exclus.
        - -ExcludeFolders est prioritaire sur -IncludeFolders. Exclure un dossier exclut ses
          sous-dossiers. Avec -IncludeFolders, seuls les dossiers correspondants (et leurs
          sous-dossiers) sont migrés.
    .PARAMETER SourceFolder
        Arborescence source (ConvertTo-EESFolderTree).
    .PARAMETER TargetFolder
        Arborescence cible (ConvertTo-EESFolderTree).
    .PARAMETER TargetRootFolder
        Dossier racine d'import dans la cible (peut contenir « / »).
    .PARAMETER IncludeFolders
        Motifs des dossiers à inclure.
    .PARAMETER ExcludeFolders
        Motifs des dossiers à exclure.
    .OUTPUTS
        Entrées du plan, triées par profondeur :
        { SourceFolderId, SourcePath, CanonicalPath, Type, TotalItemCount, TargetAnchor, TargetSegments, TargetPath, Status }.
        Status = Migrate ou Excluded (avec Reason).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$SourceFolder,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$TargetFolder,

        [string]$TargetRootFolder,

        [string[]]$IncludeFolders,

        [string[]]$ExcludeFolders
    )

    # Dossiers système jamais migrés (noms well-known, indépendants de la langue).
    $systemFolders = @(
        'searchfolders', 'syncissues', 'conflicts', 'localfailures', 'serverfailures', 'outbox',
        'recoverableitemsroot', 'recoverableitemsdeletions', 'recoverableitemspurges',
        'recoverableitemsversions', 'recoverableitemsdiscoveryholds', 'recoverableitemssubstrateholds'
    )

    $sourceById = @{}
    foreach ($folder in $SourceFolder) {
        $sourceById[$folder.Id] = $folder
    }
    $targetWellKnown = @{}
    foreach ($folder in $TargetFolder) {
        if ($folder.WellKnownName -and -not $targetWellKnown.ContainsKey($folder.WellKnownName)) {
            $targetWellKnown[$folder.WellKnownName] = $folder
        }
    }

    $rootSegments = @()
    if (-not [string]::IsNullOrWhiteSpace($TargetRootFolder)) {
        $rootSegments = @($TargetRootFolder.Replace('\', '/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() })
    }

    $hasInclude = @($IncludeFolders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0

    $plan = foreach ($folder in ($SourceFolder | Sort-Object -Property Depth, Path)) {
        # Exclusion système : le dossier ou un de ses ancêtres est un dossier système.
        $reason = $null
        $cursor = $folder
        while ($cursor) {
            if ($cursor.WellKnownName -and $systemFolders -contains $cursor.WellKnownName) {
                $reason = "Dossier système ($($cursor.WellKnownName))"
                break
            }
            $cursor = if ($cursor.ParentId -and $sourceById.ContainsKey($cursor.ParentId)) { $sourceById[$cursor.ParentId] } else { $null }
        }
        if (-not $reason -and $ExcludeFolders -and (Test-EESFolderFilter -Folder $folder -Pattern $ExcludeFolders)) {
            $reason = 'Exclu par -ExcludeFolders'
        }
        if (-not $reason -and $hasInclude -and -not (Test-EESFolderFilter -Folder $folder -Pattern $IncludeFolders)) {
            $reason = 'Non inclus par -IncludeFolders'
        }

        $anchor = $null
        if ($rootSegments.Count -gt 0) {
            $segments = @($rootSegments) + @($folder.Segments)
        }
        elseif ($folder.Anchor -and $targetWellKnown.ContainsKey($folder.Anchor)) {
            $anchor = $folder.Anchor
            $segments = @($folder.Relative)
        }
        else {
            $segments = @($folder.Segments)
        }

        $targetPath = if ($anchor) {
            (@($targetWellKnown[$anchor].Path) + @($segments)) -join '/'
        }
        else {
            $segments -join '/'
        }

        [pscustomobject]@{
            SourceFolderId = $folder.Id
            SourcePath     = $folder.Path
            CanonicalPath  = $folder.CanonicalPath
            Type           = $folder.Type
            TotalItemCount = $folder.TotalItemCount
            TargetAnchor   = $anchor
            TargetSegments = [string[]]$segments
            TargetPath     = $targetPath
            Status         = if ($reason) { 'Excluded' } else { 'Migrate' }
            Reason         = $reason
        }
    }
    return $plan
}
