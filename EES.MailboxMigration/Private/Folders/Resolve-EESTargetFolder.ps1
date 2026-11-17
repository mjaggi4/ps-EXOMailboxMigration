function Resolve-EESTargetFolder {
    <#
    .SYNOPSIS
        Retourne l'identifiant du dossier cible d'une entrée du plan, en créant les dossiers manquants.
    .DESCRIPTION
        Part du dossier well-known d'ancrage (ou de la racine), puis parcourt les segments :
        un dossier existant de même nom (casse ignorée) est réutilisé, sinon il est créé avec le
        type du dossier source (IPF.Note, IPF.Appointment...). L'index est mis à jour.
    .PARAMETER Mailbox
        Boîte cible résolue.
    .PARAMETER PlanEntry
        Entrée du plan (Get-EESFolderMappingPlan).
    .PARAMETER Index
        Index des dossiers cible (ConvertTo-EESTargetFolderIndex), mis à jour en place.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Mailbox,

        [Parameter(Mandatory)]
        [pscustomobject]$PlanEntry,

        [Parameter(Mandatory)]
        [pscustomobject]$Index
    )

    $base = "/admin/exchange/mailboxes/$($Mailbox.MailboxId)/folders"
    $graph = @{ Role = 'Target'; ApiVersion = $Mailbox.ApiVersion }

    $parentId = 'ROOT'
    if ($PlanEntry.TargetAnchor) {
        $parentId = $Index.WellKnown[$PlanEntry.TargetAnchor]
        if (-not $parentId) {
            throw "Dossier well-known '$($PlanEntry.TargetAnchor)' introuvable dans la boîte cible."
        }
    }

    $segments = @($PlanEntry.TargetSegments)
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $name = $segments[$i].Replace([string][char]0x2215, '/')
        $key = '{0}|{1}' -f $parentId, $name.ToLowerInvariant()
        if ($Index.Children.ContainsKey($key)) {
            $parentId = $Index.Children[$key]
            continue
        }

        # Les dossiers intermédiaires (ex. -TargetRootFolder) sont des dossiers de courrier.
        $type = if ($i -eq $segments.Count - 1) { $PlanEntry.Type } else { 'IPF.Note' }
        $uri = if ($parentId -eq 'ROOT') { $base } else { "$base/$parentId/childFolders" }
        try {
            $created = Invoke-EESGraphRequest @graph -Method POST -Uri $uri -Body ([ordered]@{ displayName = $name; type = $type })
            $newId = [string]$created.id
            Write-EESLog -Message "Dossier cible créé : $name ($type)" -Context $Mailbox.Identity
        }
        catch {
            if ($_.Exception.Data['StatusCode'] -notin @(400, 409)) {
                throw
            }
            # Le dossier existe déjà (créé entre-temps ou masqué de la liste) : on le recherche.
            $listUri = if ($parentId -eq 'ROOT') { "$base`?includeHiddenFolders=true" } else { "$base/$parentId/childFolders?includeHiddenFolders=true" }
            $existing = @(Invoke-EESGraphRequest @graph -Uri $listUri -All) | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
            if (-not $existing) {
                throw
            }
            $newId = [string]$existing.id
        }
        $Index.Children[$key] = $newId
        $null = $Index.Ids.Add($newId)
        $parentId = $newId
    }

    if ($parentId -eq 'ROOT') {
        throw "Entrée de plan sans dossier cible : $($PlanEntry.SourcePath)"
    }
    return $parentId
}
