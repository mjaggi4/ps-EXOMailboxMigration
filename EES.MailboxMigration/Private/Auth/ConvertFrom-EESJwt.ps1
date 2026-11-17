function ConvertFrom-EESJwt {
    <#
    .SYNOPSIS
        Décode la charge utile (payload) d'un jeton JWT, sans vérifier sa signature.
    .DESCRIPTION
        Utilisé uniquement pour lire les permissions accordées (claim « roles ») et
        l'identifiant du tenant (claim « tid ») d'un jeton déjà obtenu auprès d'Entra ID.
    .PARAMETER Token
        Jeton JWT (trois segments séparés par des points).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) {
        throw 'Jeton JWT invalide.'
    }

    # Base64url -> Base64 standard, avec remplissage.
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw 'Jeton JWT invalide (encodage base64url).' }
    }

    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
    return $json | ConvertFrom-Json
}
