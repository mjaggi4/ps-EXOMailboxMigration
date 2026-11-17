function Get-EESSasUploadUri {
    <#
    .SYNOPSIS
        Valide l'URL SAS du portail Purview et y ajoute un sous-dossier de dépôt (fonction pure).
    .DESCRIPTION
        L'URL SAS (« Show network upload SAS URL ») a la forme
        https://<compte>.blob.core.windows.net/ingestiondata?sv=...&sig=...
        Le sous-dossier est inséré après « ingestiondata » ; il devient la colonne FilePath du
        fichier de mappage (sensible à la casse).
    .PARAMETER SasUrl
        URL SAS fournie par le portail.
    .PARAMETER Folder
        Sous-dossier de dépôt (lettres, chiffres, tirets).
    .OUTPUTS
        URL complète (à ne jamais journaliser).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$SasUrl,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9\-_]+$')]
        [string]$Folder
    )

    $uri = $null
    if (-not [uri]::TryCreate($SasUrl.Trim(), [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw 'URL SAS invalide : elle doit commencer par https://'
    }
    if ($uri.Host -notlike '*.blob.core.windows.net') {
        throw "URL SAS inattendue : l'hôte doit être un stockage Azure (*.blob.core.windows.net), reçu « $($uri.Host) »."
    }
    if ($uri.Query -notmatch '(^|[?&])sig=') {
        throw 'URL SAS incomplète : la signature (sig=...) est absente. Recopiez l''URL complète depuis le portail Purview.'
    }
    $path = $uri.AbsolutePath.TrimEnd('/')
    if ($path -notmatch '(?i)/ingestiondata$') {
        throw "URL SAS inattendue : le conteneur doit être « ingestiondata » (reçu « $path »)."
    }

    $builder = [System.UriBuilder]::new($uri)
    $builder.Path = "$path/$Folder"
    return $builder.Uri.AbsoluteUri
}
