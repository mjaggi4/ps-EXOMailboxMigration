# Initialisation commune des tests : dossiers de travail isolés puis import du module.
param(
    [Parameter(Mandatory)]
    [string]$TestRoot
)

$env:EES_MAILBOXMIGRATION_HOME = Join-Path -Path $TestRoot -ChildPath 'home'
$env:EES_MAILBOXMIGRATION_CONFIG = Join-Path -Path $TestRoot -ChildPath 'config'
$env:EES_MAILBOXMIGRATION_LOGFILE = $null

$manifest = Join-Path -Path $PSScriptRoot -ChildPath '..\EES.MailboxMigration\EES.MailboxMigration.psd1'
Import-Module -Name $manifest -Force -WarningAction SilentlyContinue
