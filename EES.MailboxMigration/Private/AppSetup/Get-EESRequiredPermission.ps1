function Get-EESRequiredPermission {
    <#
    .SYNOPSIS
        Retourne les permissions applicatives Microsoft Graph nécessaires pour un ou plusieurs rôles.
    .DESCRIPTION
        Noms vérifiés sur Microsoft Learn (API mailbox import/export, v1.0) :
        - Source : lecture des dossiers et éléments, export des éléments.
        - Target : création des dossiers, import des éléments, lecture (delta, contrôle anti-doublons).
        - Les deux : User.Read.All (GET /users/{id}/settings/exchange, licences),
          Organization.Read.All (nom du tenant, abonnements pour les pré-vérifications),
          Reports.Read.All (taille, nombre d'éléments et quota des boîtes : getMailboxUsageDetail).
    .PARAMETER Role
        Un ou plusieurs rôles.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string[]]$Role
    )

    $map = @{
        Source = @(
            'User.Read.All'
            'Organization.Read.All'
            'Reports.Read.All'
            'MailboxFolder.Read.All'
            'MailboxItem.Read.All'
            'MailboxItem.Export.All'
        )
        Target = @(
            'User.Read.All'
            'Organization.Read.All'
            'Reports.Read.All'
            'MailboxFolder.ReadWrite.All'
            'MailboxItem.Read.All'
            'MailboxItem.ImportExport.All'
        )
    }

    $permissions = foreach ($r in $Role) { $map[$r] }
    return [string[]]@($permissions | Sort-Object -Unique)
}
