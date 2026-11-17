function Get-EESImportSession {
    <#
    .SYNOPSIS
        Retourne une session d'import valide (importUrl pré-authentifiée) pour une boîte cible.
    .DESCRIPTION
        Les sessions sont mises en cache par boîte et renouvelées 5 minutes avant expiration
        (ou immédiatement avec -Force). L'importUrl contient un jeton : elle n'est jamais journalisée.
    .PARAMETER Mailbox
        Boîte cible résolue (pour la version d'API).
    .PARAMETER MailboxId
        Identifiant de la boîte (peut différer de Mailbox.MailboxId pour une archive auxiliaire).
    .PARAMETER Force
        Crée une nouvelle session.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Mailbox,

        [Parameter(Mandatory)]
        [string]$MailboxId,

        [switch]$Force
    )

    if (-not $script:EESImportSessions) {
        $script:EESImportSessions = @{}
    }
    $session = $script:EESImportSessions[$MailboxId]
    $limit = (Get-Date).ToUniversalTime().AddMinutes(5)
    if (-not $Force -and $session -and $session.ExpiresAt -gt $limit) {
        return $session
    }

    $response = Invoke-EESGraphRequest -Role Target -Method POST -Uri "/admin/exchange/mailboxes/$MailboxId/createImportSession" -ApiVersion $Mailbox.ApiVersion
    if (-not $response.importUrl) {
        throw "Création de la session d'import impossible pour $($Mailbox.Identity) : réponse sans importUrl."
    }
    $expires = if ($response.expirationDateTime) { ([datetime]$response.expirationDateTime).ToUniversalTime() } else { (Get-Date).ToUniversalTime().AddMinutes(30) }
    $session = [pscustomobject]@{
        ImportUrl = [string]$response.importUrl
        ExpiresAt = $expires
    }
    $script:EESImportSessions[$MailboxId] = $session
    Write-EESLog -Level DEBUG -Message ("Session d'import créée (expire à {0:HH:mm:ss} UTC)." -f $expires) -Context $Mailbox.Identity
    return $session
}
