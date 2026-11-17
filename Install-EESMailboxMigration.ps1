<#
.SYNOPSIS
    Installe le module EES.MailboxMigration et ses prérequis.

.DESCRIPTION
    Compatible Windows PowerShell 5.1 (c'est le script à lancer en premier) :
      1. Vérifie PowerShell 7.4+ ; s'il est absent, propose de l'installer avec winget
         (winget install Microsoft.PowerShell), puis relance ce script dans pwsh.
      2. Vérifie la stratégie d'exécution et propose RemoteSigned pour l'utilisateur courant.
      3. Débloque les fichiers téléchargés (Unblock-File).
      4. Installe ou met à jour, pour l'utilisateur courant, les modules nécessaires avec des
         versions minimales : Microsoft.Graph.Authentication, ExchangeOnlineManagement, et
         Az.Accounts / Az.Storage avec -IncludeAzureModules.
      5. Copie le module dans le dossier des modules PowerShell 7 de l'utilisateur.
      6. Télécharge AzCopy avec -InstallAzCopy (sinon téléchargé à la demande lors d'un import PST).

.PARAMETER IncludeAzureModules
    Installe aussi Az.Accounts et Az.Storage (réservés à la future méthode Azure PST Import).

.PARAMETER InstallAzCopy
    Télécharge AzCopy immédiatement.

.PARAMETER NoModuleCopy
    N'installe pas le module dans le dossier des modules : il sera importé depuis ce dossier.

.PARAMETER Force
    Répond « oui » à toutes les questions.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Install-EESMailboxMigration.ps1

    Installation guidée depuis Windows PowerShell 5.1.

.EXAMPLE
    .\Install-EESMailboxMigration.ps1 -Force -InstallAzCopy

    Installation sans question, AzCopy compris.
#>
[CmdletBinding()]
param(
    [switch]$IncludeAzureModules,

    [switch]$InstallAzCopy,

    [switch]$NoModuleCopy,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$minimumPowerShell = [version]'7.4'
$requiredModules = [ordered]@{
    'Microsoft.Graph.Authentication' = '2.25.0'
    'ExchangeOnlineManagement'       = '3.5.0'
}
$azureModules = [ordered]@{
    'Az.Accounts' = '3.0.0'
    'Az.Storage'  = '7.0.0'
}

function Write-InstallMessage {
    param(
        [string]$Message,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::Gray
    )
    $Host.UI.WriteLine($Color, $Host.UI.RawUI.BackgroundColor, $Message)
}

function Confirm-InstallStep {
    param([string]$Question)
    if ($Force) {
        return $true
    }
    $answer = Read-Host -Prompt "$Question (O/n)"
    return ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(?i)(o|oui|y|yes)$')
}

Write-InstallMessage -Message '=== Installation de EES.MailboxMigration ===' -Color Cyan

# --- 1. PowerShell 7 ------------------------------------------------------------------------------------
if ($PSVersionTable.PSVersion -lt $minimumPowerShell) {
    Write-InstallMessage -Message ("PowerShell {0} détecté : PowerShell {1} ou supérieur est obligatoire." -f $PSVersionTable.PSVersion, $minimumPowerShell) -Color Yellow

    $pwshPath = $null
    $command = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Version -ge $minimumPowerShell) {
        $pwshPath = $command.Source
    }
    $defaultPath = Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\7\pwsh.exe'
    if (-not $pwshPath -and (Test-Path -LiteralPath $defaultPath)) {
        $pwshPath = $defaultPath
    }

    if (-not $pwshPath) {
        if (-not (Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue)) {
            throw 'PowerShell 7 est absent et winget est indisponible. Installez PowerShell 7 depuis https://aka.ms/powershell puis relancez ce script.'
        }
        if (-not (Confirm-InstallStep -Question 'Installer PowerShell 7 avec winget ?')) {
            throw 'Installation annulée : PowerShell 7 est obligatoire.'
        }
        & winget.exe install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
        if (-not (Test-Path -LiteralPath $defaultPath)) {
            throw "PowerShell 7 n'a pas été trouvé après l'installation ($defaultPath). Ouvrez une nouvelle session et relancez ce script."
        }
        $pwshPath = $defaultPath
    }

    Write-InstallMessage -Message "Relance de l'installation dans PowerShell 7 ($pwshPath)..." -Color Cyan
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($name in $PSBoundParameters.Keys) {
        $arguments += "-$name"
    }
    & $pwshPath @arguments
    exit $LASTEXITCODE
}

# --- 2. Stratégie d'exécution --------------------------------------------------------------------------
$policy = Get-ExecutionPolicy
if ($policy -in @('Restricted', 'AllSigned', 'Undefined')) {
    Write-InstallMessage -Message "Stratégie d'exécution actuelle : $policy (les scripts du module ne pourront pas se charger)." -Color Yellow
    if (Confirm-InstallStep -Question 'Définir la stratégie RemoteSigned pour votre compte (CurrentUser) ?') {
        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        }
        catch {
            Write-InstallMessage -Message "Impossible de modifier la stratégie (probablement imposée par une GPO) : $($_.Exception.Message)" -Color Yellow
        }
    }
}

# --- 3. Déblocage des fichiers téléchargés -----------------------------------------------------------------
Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Unblock-File
Write-InstallMessage -Message 'Fichiers débloqués.' -Color Green

# --- 4. Modules requis ----------------------------------------------------------------------------------------
$modules = [ordered]@{}
foreach ($key in $requiredModules.Keys) {
    $modules[$key] = $requiredModules[$key]
}
if ($IncludeAzureModules) {
    foreach ($key in $azureModules.Keys) {
        $modules[$key] = $azureModules[$key]
    }
}
foreach ($name in $modules.Keys) {
    $minimum = [version]$modules[$name]
    $installed = Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -ge $minimum } | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($installed) {
        Write-InstallMessage -Message ("{0} {1} : déjà installé." -f $name, $installed.Version) -Color Green
        continue
    }
    Write-InstallMessage -Message ("Installation de {0} (version {1} minimum, pour votre compte)..." -f $name, $minimum)
    Install-Module -Name $name -MinimumVersion $minimum -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
}

# --- 5. Copie du module ----------------------------------------------------------------------------------------
$source = Join-Path -Path $PSScriptRoot -ChildPath 'EES.MailboxMigration'
$manifest = Import-PowerShellDataFile -Path (Join-Path -Path $source -ChildPath 'EES.MailboxMigration.psd1')
$manifestPath = Join-Path -Path $source -ChildPath 'EES.MailboxMigration.psd1'
if (-not $NoModuleCopy) {
    $modulesRoot = Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'PowerShell\Modules'
    $destination = Join-Path -Path $modulesRoot -ChildPath ("EES.MailboxMigration\{0}" -f $manifest.ModuleVersion)
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    $null = New-Item -Path $destination -ItemType Directory -Force
    Copy-Item -Path (Join-Path -Path $source -ChildPath '*') -Destination $destination -Recurse -Force
    $manifestPath = Join-Path -Path $destination -ChildPath 'EES.MailboxMigration.psd1'
    Write-InstallMessage -Message "Module installé dans $destination" -Color Green
}

# --- 6. Vérification et AzCopy -----------------------------------------------------------------------------------
Import-Module -Name $manifestPath -Force
$count = @(Get-Command -Module EES.MailboxMigration).Count
Write-InstallMessage -Message "Module chargé : $count commandes disponibles." -Color Green

if ($InstallAzCopy) {
    $azcopy = & (Get-Module -Name EES.MailboxMigration) { Get-EESAzCopy }
    Write-InstallMessage -Message "AzCopy disponible : $azcopy" -Color Green
}

Write-InstallMessage -Message ''
Write-InstallMessage -Message 'Installation terminée. Pour commencer, dans PowerShell 7 :' -Color Cyan
if ($NoModuleCopy) {
    Write-InstallMessage -Message "    Import-Module '$manifestPath'" -Color Cyan
}
else {
    Write-InstallMessage -Message '    Import-Module EES.MailboxMigration' -Color Cyan
}
Write-InstallMessage -Message '    Start-EESMigrationMenu' -Color Cyan
