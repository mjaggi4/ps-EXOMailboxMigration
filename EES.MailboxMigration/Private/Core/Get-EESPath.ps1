function Get-EESPath {
    <#
    .SYNOPSIS
        Retourne (et crée si besoin) un dossier de travail du module.
    .DESCRIPTION
        - Config  : %APPDATA%\EES.MailboxMigration (tenants.json, sans secret).
                    Surchargeable par la variable d'environnement EES_MAILBOXMIGRATION_CONFIG.
        - Root    : dossier de travail (%LOCALAPPDATA%\EES.MailboxMigration par défaut).
                    Surchargeable par la variable d'environnement EES_MAILBOXMIGRATION_HOME.
        - Logs, State, Reports, Tools : sous-dossiers du dossier de travail.
    .PARAMETER Kind
        Type de dossier demandé.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Config', 'Root', 'Logs', 'State', 'Reports', 'Tools')]
        [string]$Kind
    )

    $moduleName = 'EES.MailboxMigration'

    if ($Kind -eq 'Config') {
        $path = if ($env:EES_MAILBOXMIGRATION_CONFIG) {
            $env:EES_MAILBOXMIGRATION_CONFIG
        }
        elseif ($env:APPDATA) {
            Join-Path -Path $env:APPDATA -ChildPath $moduleName
        }
        else {
            Join-Path -Path $HOME -ChildPath ".config/$moduleName"
        }
    }
    else {
        $root = if ($env:EES_MAILBOXMIGRATION_HOME) {
            $env:EES_MAILBOXMIGRATION_HOME
        }
        elseif ($env:LOCALAPPDATA) {
            Join-Path -Path $env:LOCALAPPDATA -ChildPath $moduleName
        }
        else {
            Join-Path -Path $HOME -ChildPath ".local/share/$moduleName"
        }
        $path = if ($Kind -eq 'Root') { $root } else { Join-Path -Path $root -ChildPath $Kind }
    }

    if (-not (Test-Path -LiteralPath $path)) {
        $null = New-Item -Path $path -ItemType Directory -Force
    }
    return $path
}
