function Assert-EESPrerequisites {
    <#
    .SYNOPSIS
        Vérifie les prérequis du module et affiche des messages clairs.
    .DESCRIPTION
        - Avec -WarningOnly (au chargement du module) : affiche des avertissements sans bloquer.
        - Avec -Require : lève une erreur explicite si un composant requis est absent.
    .PARAMETER Require
        Composants requis : Graph (Microsoft.Graph.Authentication, pour MSAL),
        ExchangeOnline (ExchangeOnlineManagement), Windows (magasin de certificats Windows).
    .PARAMETER WarningOnly
        N'affiche que des avertissements.
    #>
    # Nom imposé par le cahier des charges (pluriel volontaire).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param(
        [ValidateSet('Graph', 'ExchangeOnline', 'Windows')]
        [string[]]$Require = @(),

        [switch]$WarningOnly
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    if ($PSVersionTable.PSVersion -lt [version]'7.4') {
        $problems.Add("PowerShell 7.4 ou supérieur est obligatoire (version actuelle : $($PSVersionTable.PSVersion)). Lancez Install-EESMailboxMigration.ps1.")
    }

    $checkGraph = $WarningOnly -or ($Require -contains 'Graph')
    if ($checkGraph) {
        $graphModule = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' |
            Where-Object { $_.Version -ge $script:EESConstants.MinGraphAuthVersion } |
            Sort-Object -Property Version -Descending | Select-Object -First 1
        if (-not $graphModule) {
            $problems.Add(("Le module Microsoft.Graph.Authentication (version {0} ou supérieure) est introuvable. " +
                    "Installez-le avec : Install-Module Microsoft.Graph.Authentication -Scope CurrentUser") -f $script:EESConstants.MinGraphAuthVersion)
        }
    }

    if ($Require -contains 'ExchangeOnline') {
        if (-not (Get-Module -ListAvailable -Name 'ExchangeOnlineManagement')) {
            $problems.Add('Le module ExchangeOnlineManagement est introuvable. Installez-le avec : Install-Module ExchangeOnlineManagement -Scope CurrentUser')
        }
    }

    $checkWindows = $WarningOnly -or ($Require -contains 'Windows')
    if ($checkWindows -and -not $IsWindows) {
        $problems.Add("Ce module utilise le magasin de certificats Windows (Cert:\CurrentUser\My) : il doit être exécuté sous Windows.")
    }

    if ($problems.Count -eq 0) {
        return
    }

    if ($WarningOnly) {
        foreach ($problem in $problems) {
            Write-Warning -Message "[EES.MailboxMigration] $problem"
        }
        return
    }

    throw ("Prérequis manquants :`n - " + ($problems -join "`n - "))
}
