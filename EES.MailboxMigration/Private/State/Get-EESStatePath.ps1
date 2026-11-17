function Get-EESStatePath {
    <#
    .SYNOPSIS
        Retourne (et crée) le dossier d'état d'une paire de boîtes.
    .DESCRIPTION
        Un dossier par paire source/cible (et par type : principale ou archive) :
        State\<source>__<cible>[__archive]. Les caractères interdits sont remplacés par « _ ».
    .PARAMETER SourceIdentity
        Adresse de la boîte source.
    .PARAMETER TargetIdentity
        Adresse de la boîte cible.
    .PARAMETER Archive
        Paire de boîtes d'archive.
    .PARAMETER TargetRootFolder
        Dossier racine d'import : un état distinct est tenu par dossier racine, pour qu'un test
        dans « Migration-Test » n'empêche pas la vraie migration de copier les mêmes éléments.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceIdentity,

        [Parameter(Mandatory)]
        [string]$TargetIdentity,

        [switch]$Archive,

        [string]$TargetRootFolder
    )

    $name = '{0}__{1}' -f (ConvertTo-EESSafeFileName -Name $SourceIdentity), (ConvertTo-EESSafeFileName -Name $TargetIdentity)
    if ($Archive) {
        $name += '__archive'
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetRootFolder)) {
        $name += '__root-' + (ConvertTo-EESSafeFileName -Name $TargetRootFolder.Trim().Trim('/', '\'))
    }
    $path = Join-Path -Path (Get-EESPath -Kind State) -ChildPath $name
    if (-not (Test-Path -LiteralPath $path)) {
        $null = New-Item -Path $path -ItemType Directory -Force
    }
    return $path
}
