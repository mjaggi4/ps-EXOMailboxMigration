function Get-EESItemAction {
    <#
    .SYNOPSIS
        Détermine le traitement d'un élément renvoyé par delta (fonction pure).
    .DESCRIPTION
        - Removed  : élément supprimé dans la source (@removed) : rien n'est supprimé dans la cible.
        - Skip     : déjà migré dans sa version actuelle (même changeKey dans le journal).
        - Update   : déjà migré mais modifié depuis : réimport en mode « update ».
        - Filtered : hors de la plage -StartDate / -EndDate (sur createdDateTime).
        - Create   : à copier.
    .PARAMETER Item
        Élément delta (id, changeKey, createdDateTime, size, éventuellement @removed).
    .PARAMETER Journal
        Dictionnaire SourceItemId -> entrée du journal.
    .PARAMETER StartDate
        Date de début (incluse).
    .PARAMETER EndDate
        Date de fin (exclue).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Item,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$Journal,

        [Nullable[datetime]]$StartDate,

        [Nullable[datetime]]$EndDate
    )

    if ($Item.PSObject.Properties['@removed']) {
        return 'Removed'
    }

    $id = [string]$Item.id
    if ($Journal.ContainsKey($id)) {
        $entry = $Journal[$id]
        if ([string]$entry.SourceChangeKey -eq [string]$Item.changeKey) {
            return 'Skip'
        }
        return 'Update'
    }

    if ($StartDate -or $EndDate) {
        $created = $null
        if ($Item.PSObject.Properties['createdDateTime'] -and $Item.createdDateTime) {
            $created = ([datetime]$Item.createdDateTime).ToUniversalTime()
        }
        if ($created) {
            if ($StartDate -and $created -lt ([datetime]$StartDate).ToUniversalTime()) {
                return 'Filtered'
            }
            if ($EndDate -and $created -ge ([datetime]$EndDate).ToUniversalTime()) {
                return 'Filtered'
            }
        }
    }
    return 'Create'
}
