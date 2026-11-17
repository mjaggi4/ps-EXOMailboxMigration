function Resolve-EESMailbox {
    <#
    .SYNOPSIS
        Résout l'identifiant « mailbox import/export » (MBX:...) d'une boîte principale ou d'archive.
    .DESCRIPTION
        - Boîte principale : GET /users/{upn}/settings/exchange (v1.0) -> primaryMailboxId.
        - Archive : l'identifiant n'est publié que par la version beta du même appel
          (inPlaceArchiveMailboxId). Les opérations sur l'archive sont ensuite tentées en v1.0,
          avec repli sur la beta si la v1.0 refuse cet identifiant.
    .PARAMETER Role
        Tenant concerné.
    .PARAMETER Identity
        UPN ou adresse de la boîte.
    .PARAMETER Archive
        Résout la boîte d'archive au lieu de la boîte principale.
    .OUTPUTS
        { Identity, UserId, DisplayName, MailboxId, ApiVersion, IsArchive }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [Parameter(Mandatory)]
        [string]$Identity,

        [switch]$Archive
    )

    $escaped = [uri]::EscapeDataString($Identity)
    try {
        $user = Invoke-EESGraphRequest -Role $Role -Uri "/users/$escaped`?`$select=id,userPrincipalName,displayName,mail"
    }
    catch {
        if ($_.Exception.Data['StatusCode'] -eq 404) {
            throw "Utilisateur introuvable dans le tenant $Role : $Identity"
        }
        throw
    }

    $settingsVersion = if ($Archive) { 'beta' } else { 'v1.0' }
    try {
        $settings = Invoke-EESGraphRequest -Role $Role -Uri "/users/$($user.id)/settings/exchange" -ApiVersion $settingsVersion
    }
    catch {
        throw "Aucune boîte Exchange Online accessible pour $Identity ($Role) : $($_.Exception.Message)"
    }

    if (-not $Archive) {
        if (-not $settings.primaryMailboxId) {
            throw "Aucune boîte aux lettres principale pour $Identity ($Role)."
        }
        return [pscustomobject]@{
            Identity    = $user.userPrincipalName
            UserId      = $user.id
            DisplayName = $user.displayName
            MailboxId   = [string]$settings.primaryMailboxId
            ApiVersion  = 'v1.0'
            IsArchive   = $false
        }
    }

    $archiveId = if ($settings.PSObject.Properties['inPlaceArchiveMailboxId']) { [string]$settings.inPlaceArchiveMailboxId } else { $null }
    if (-not $archiveId) {
        throw "La boîte d'archive n'est pas activée (ou pas encore provisionnée) pour $Identity ($Role)."
    }

    # Essai v1.0, puis repli beta.
    $apiVersion = $null
    foreach ($version in @('v1.0', 'beta')) {
        try {
            $null = Invoke-EESGraphRequest -Role $Role -Uri "/admin/exchange/mailboxes/$archiveId/folders?`$top=1" -ApiVersion $version
            $apiVersion = $version
            break
        }
        catch {
            Write-EESLog -Level DEBUG -Message "Archive $Identity : accès $version refusé ($($_.Exception.Message))."
        }
    }
    if (-not $apiVersion) {
        throw "La boîte d'archive de $Identity ($Role) n'est pas accessible par l'API mailbox import/export."
    }
    if ($apiVersion -eq 'beta') {
        Write-EESLog -Level WARN -Message "Archive de $Identity : accès uniquement via l'API beta de Microsoft Graph (non supportée en production par Microsoft)."
    }

    return [pscustomobject]@{
        Identity    = $user.userPrincipalName
        UserId      = $user.id
        DisplayName = $user.displayName
        MailboxId   = $archiveId
        ApiVersion  = $apiVersion
        IsArchive   = $true
    }
}
