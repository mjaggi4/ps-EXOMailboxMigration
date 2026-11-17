function ConvertTo-EESImportBody {
    <#
    .SYNOPSIS
        Construit le corps JSON d'un import d'élément (fonction pure).
    .DESCRIPTION
        Format documenté : { FolderId, Mode (create|update), Data [, ItemId, ChangeKey] }.
        Le flux Data (base64, potentiellement volumineux) est concaténé tel quel, sans
        resérialisation, après vérification qu'il ne contient que des caractères base64.
    .PARAMETER FolderId
        Identifiant du dossier cible (mailboxFolder.id).
    .PARAMETER Data
        Flux exporté (base64 opaque, jamais analysé).
    .PARAMETER TargetItemId
        Identifiant de l'élément cible (mode update).
    .PARAMETER TargetChangeKey
        Version de l'élément cible (mode update).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderId,

        [Parameter(Mandatory)]
        [string]$Data,

        [string]$TargetItemId,

        [string]$TargetChangeKey
    )

    if ($Data -notmatch '^[A-Za-z0-9+/=\r\n]*$') {
        throw 'Flux exporté invalide (caractères non base64).'
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('"FolderId":' + (ConvertTo-Json -InputObject $FolderId -Compress))
    if ($TargetItemId) {
        $parts.Add('"Mode":"update"')
        $parts.Add('"ItemId":' + (ConvertTo-Json -InputObject $TargetItemId -Compress))
        $parts.Add('"ChangeKey":' + (ConvertTo-Json -InputObject $TargetChangeKey -Compress))
    }
    else {
        $parts.Add('"Mode":"create"')
    }
    $parts.Add('"Data":"' + $Data + '"')
    return '{' + ($parts -join ',') + '}'
}
