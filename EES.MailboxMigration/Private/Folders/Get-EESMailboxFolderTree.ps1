function Get-EESMailboxFolderTree {
    <#
    .SYNOPSIS
        Retourne tous les dossiers (non cachés) d'une boîte, avec leur chemin complet.
    .DESCRIPTION
        Parcourt /folders puis /childFolders en largeur, sans doublon (la liste racine peut ou
        non contenir les sous-dossiers). Le chemin est calculé par ConvertTo-EESFolderTree.
    .PARAMETER Role
        Tenant concerné.
    .PARAMETER Mailbox
        Boîte résolue (Resolve-EESMailbox).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [Parameter(Mandatory)]
        [pscustomobject]$Mailbox
    )

    $select = '$select=id,displayName,parentFolderId,wellKnownName,type,totalItemCount,childFolderCount'
    $base = "/admin/exchange/mailboxes/$($Mailbox.MailboxId)/folders"
    $graph = @{ Role = $Role; ApiVersion = $Mailbox.ApiVersion; All = $true }

    $folders = [ordered]@{}
    foreach ($folder in @(Invoke-EESGraphRequest @graph -Uri "$base`?$select")) {
        $folders[[string]$folder.id] = $folder
    }

    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($folder in @($folders.Values)) {
        $queue.Enqueue($folder)
    }
    while ($queue.Count -gt 0) {
        $folder = $queue.Dequeue()
        if ([int]$folder.childFolderCount -le 0) {
            continue
        }
        $knownChildren = @($folders.Values | Where-Object { $_.parentFolderId -eq $folder.id }).Count
        if ($knownChildren -ge [int]$folder.childFolderCount) {
            continue
        }
        $children = @(Invoke-EESGraphRequest @graph -Uri "$base/$($folder.id)/childFolders?$select")
        foreach ($child in $children) {
            if (-not $folders.Contains([string]$child.id)) {
                $folders[[string]$child.id] = $child
                $queue.Enqueue($child)
            }
        }
    }

    return ConvertTo-EESFolderTree -Folder @($folders.Values)
}
