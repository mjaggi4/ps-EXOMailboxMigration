function Get-EESAzCopy {
    <#
    .SYNOPSIS
        Retourne le chemin d'AzCopy, en le téléchargeant si nécessaire.
    .DESCRIPTION
        Ordre de recherche : -Path fourni, dossier Tools du module de travail, PATH du système.
        Sinon, téléchargement de la version 10 officielle de Microsoft (https://aka.ms/downloadazcopy-v10-windows)
        dans le dossier Tools, puis vérification de la signature Authenticode (éditeur Microsoft).
    .PARAMETER Path
        Chemin explicite d'azcopy.exe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path
    )

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "AzCopy introuvable : $Path"
        }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $toolsDirectory = Join-Path -Path (Get-EESPath -Kind Tools) -ChildPath 'azcopy'
    $existing = Get-ChildItem -LiteralPath $toolsDirectory -Filter 'azcopy.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        return $existing.FullName
    }
    $inPath = Get-Command -Name 'azcopy' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($inPath) {
        return $inPath.Source
    }

    if (-not $IsWindows) {
        throw 'AzCopy introuvable : installez-le (https://aka.ms/downloadazcopy) ou indiquez son chemin avec -AzCopyPath.'
    }

    Write-EESMessage -Message 'Téléchargement d''AzCopy (Microsoft)...'
    $null = New-Item -Path $toolsDirectory -ItemType Directory -Force
    $zip = Join-Path -Path $toolsDirectory -ChildPath 'azcopy.zip'
    Invoke-WebRequest -Uri 'https://aka.ms/downloadazcopy-v10-windows' -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $toolsDirectory -Force
    Remove-Item -LiteralPath $zip -Force

    $exe = Get-ChildItem -LiteralPath $toolsDirectory -Filter 'azcopy.exe' -Recurse | Select-Object -First 1
    if (-not $exe) {
        throw 'Le téléchargement d''AzCopy n''a pas fourni azcopy.exe.'
    }
    $signature = Get-AuthenticodeSignature -FilePath $exe.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Remove-Item -LiteralPath $toolsDirectory -Recurse -Force
        throw "Signature d'AzCopy invalide ($($signature.Status)) : fichier supprimé par sécurité."
    }
    Write-EESLog -Message "AzCopy installé : $($exe.FullName)"
    return $exe.FullName
}
