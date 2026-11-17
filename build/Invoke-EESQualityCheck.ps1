#Requires -Version 7.4
<#
.SYNOPSIS
    Lance PSScriptAnalyzer puis les tests Pester (même contrôle que l'intégration continue).
.PARAMETER Path
    Racine du dépôt.
.PARAMETER CI
    Mode intégration continue : produit un fichier de résultats NUnit et sort en erreur si échec.
#>
[CmdletBinding()]
param(
    [string]$Path = (Split-Path -Path $PSScriptRoot -Parent),
    [switch]$CI
)

$ErrorActionPreference = 'Stop'

Import-Module PSScriptAnalyzer -MinimumVersion 1.21.0
Import-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99

# --- PSScriptAnalyzer -------------------------------------------------------------------------
$settings = Join-Path -Path $Path -ChildPath 'PSScriptAnalyzerSettings.psd1'
$targets = @(
    (Join-Path -Path $Path -ChildPath 'EES.MailboxMigration')
    (Join-Path -Path $Path -ChildPath 'build')
)
$installer = Join-Path -Path $Path -ChildPath 'Install-EESMailboxMigration.ps1'
if (Test-Path -LiteralPath $installer) {
    $targets += $installer
}

$findings = foreach ($target in $targets) {
    # PSScriptAnalyzer échoue parfois de façon aléatoire (erreur interne) : une nouvelle tentative.
    try {
        Invoke-ScriptAnalyzer -Path $target -Recurse -Settings $settings -ErrorAction Stop
    }
    catch {
        Write-Warning -Message "PSScriptAnalyzer : erreur interne ($($_.Exception.Message)), nouvelle tentative."
        Invoke-ScriptAnalyzer -Path $target -Recurse -Settings $settings -ErrorAction Stop
    }
}
# L'installeur doit aussi rester compatible avec Windows PowerShell 5.1.
if (Test-Path -LiteralPath $installer) {
    $compatibility = @{
        IncludeRules = @('PSUseCompatibleSyntax')
        Rules        = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.4') } }
    }
    $findings = @($findings) + @(Invoke-ScriptAnalyzer -Path $installer -Settings $compatibility)
    $findings = @($findings | Where-Object { $_ })
}

if ($findings) {
    $findings | Format-Table -Property RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Output
    throw "PSScriptAnalyzer : $(@($findings).Count) problème(s) détecté(s)."
}
Write-Output 'PSScriptAnalyzer : aucun problème.'

# --- Pester -------------------------------------------------------------------------------------
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path -Path $Path -ChildPath 'Tests'
$configuration.Run.Exit = [bool]$CI
$configuration.Output.Verbosity = 'Detailed'
if ($CI) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = Join-Path -Path $Path -ChildPath 'testResults.xml'
}
$configuration.Run.PassThru = $true
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0) {
    throw "Pester : $($result.FailedCount) test(s) en échec."
}
