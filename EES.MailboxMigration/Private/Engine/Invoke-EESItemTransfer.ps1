function Invoke-EESItemTransfer {
    <#
    .SYNOPSIS
        Transfère un lot d'éléments : export source -> import cible -> journal / échecs / statistiques.
    .PARAMETER SourceMailbox
        Boîte source résolue.
    .PARAMETER TargetMailbox
        Boîte cible résolue.
    .PARAMETER State
        État de migration (journal et échecs mis à jour en place).
    .PARAMETER Work
        Éléments : { SourceItemId, Size, SourceFolderId, SourcePath, FolderId, TargetItemId,
        TargetChangeKey, TargetMailboxId }.
    .PARAMETER Stats
        Statistiques par dossier source (hashtable SourceFolderId -> compteurs), mises à jour en place.
    .PARAMETER ImportConcurrency
        Nombre d'imports simultanés.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$SourceMailbox,

        [Parameter(Mandatory)]
        [pscustomobject]$TargetMailbox,

        [Parameter(Mandatory)]
        [pscustomobject]$State,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Work,

        [Parameter(Mandatory)]
        [hashtable]$Stats,

        [ValidateRange(1, 4)]
        [int]$ImportConcurrency = 4
    )

    if ($Work.Count -eq 0) {
        return
    }

    $recordFailure = {
        param($w, [string]$message)
        $id = [string]$w.SourceItemId
        $previous = $State.Failures[$id]
        $State.Failures[$id] = [ordered]@{
            SourceFolderId = $w.SourceFolderId
            FolderPath     = $w.SourcePath
            Size           = [long]$w.Size
            Error          = $message
            Attempts       = if ($previous) { [int]$previous.Attempts + 1 } else { 1 }
            LastAttempt    = (Get-Date).ToUniversalTime().ToString('o')
        }
        $Stats[$w.SourceFolderId].Failed++
        Write-EESLog -Level WARN -Context $SourceMailbox.Identity -Message ("Élément en échec [{0}] dossier « {1} », {2:N0} octets : {3}" -f $id, $w.SourcePath, [long]$w.Size, $message)
    }

    $workById = @{}
    foreach ($w in $Work) {
        $workById[[string]$w.SourceItemId] = $w
        if (-not $Stats.ContainsKey($w.SourceFolderId)) {
            $Stats[$w.SourceFolderId] = ConvertTo-EESFolderStat -SourcePath $w.SourcePath
        }
    }

    $exported = Export-EESMailboxItemBatch -Mailbox $SourceMailbox -Item $Work

    $entries = [System.Collections.Generic.List[object]]::new()
    $sourceChangeKeys = @{}
    foreach ($w in $Work) {
        $id = [string]$w.SourceItemId
        $result = if ($exported.ContainsKey($id)) { $exported[$id] } else { $null }
        if (-not $result -or $result.Error -or -not $result.Data) {
            $message = if ($result -and $result.Error) { $result.Error } else { 'Export vide.' }
            & $recordFailure $w $message
            continue
        }
        $sourceChangeKeys[$id] = $result.ChangeKey
        $entries.Add([pscustomobject]@{
                SourceItemId    = $id
                FolderId        = $w.FolderId
                Data            = $result.Data
                TargetItemId    = $w.TargetItemId
                TargetChangeKey = $w.TargetChangeKey
                TargetMailboxId = $w.TargetMailboxId
            })
    }
    $exported.Clear()

    $imported = Import-EESMailboxItemBatch -Mailbox $TargetMailbox -Entry $entries.ToArray() -Concurrency $ImportConcurrency
    $entries.Clear()

    $journal = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $sourceChangeKeys.Keys) {
        $w = $workById[$id]
        $result = if ($imported.ContainsKey($id)) { $imported[$id] } else { $null }
        if (-not $result -or $result.Error) {
            $message = if ($result) { $result.Error } else { 'Aucun résultat d''import.' }
            & $recordFailure $w $message
            continue
        }
        $journal.Add([pscustomobject]@{
                SourceItemId    = $id
                TargetItemId    = $result.TargetItemId
                SourceChangeKey = $sourceChangeKeys[$id]
                TargetChangeKey = $result.TargetChangeKey
                TargetMailboxId = $result.TargetMailboxId
                SourceFolderId  = $w.SourceFolderId
            })
        if ($w.TargetItemId) {
            $Stats[$w.SourceFolderId].Updated++
        }
        else {
            $Stats[$w.SourceFolderId].Copied++
        }
        $Stats[$w.SourceFolderId].Bytes += [long]$w.Size
        $null = $State.Failures.Remove($id)
    }
    Add-EESItemJournal -State $State -Entry $journal.ToArray()
}
