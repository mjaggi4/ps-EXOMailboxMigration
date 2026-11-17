function Get-EESRedirectMailboxId {
    <#
    .SYNOPSIS
        Extrait l'identifiant de boîte indiqué par une erreur 409 d'import (archive auxiliaire).
    .DESCRIPTION
        Exemple de message : « Invalid import session. The target session is expected in mailbox
        MBX:f10964a6-...@4d2e-.... » -> MBX:f10964a6-...@4d2e-...
    .PARAMETER Message
        Message d'erreur.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Message
    )

    if ($Message -match '(MBX:[0-9A-Za-z\-]+@[0-9A-Za-z\-]+)') {
        return $Matches[1]
    }
    return $null
}
