function Initialize-EESMsal {
    <#
    .SYNOPSIS
        Charge la bibliothèque MSAL.NET fournie par le module Microsoft.Graph.Authentication.
    .DESCRIPTION
        Microsoft.Graph.Authentication isole ses dépendances : ses types MSAL ne sont pas
        accessibles directement. On charge donc explicitement Microsoft.IdentityModel.Abstractions
        puis Microsoft.Identity.Client (build .NET Core) depuis la version la plus récente du module.

        Ordre de chargement : charger ce module AVANT de se connecter à Exchange Online garantit
        que la version la plus récente de MSAL est utilisée par les deux modules.
        Si une version de MSAL est déjà chargée (ex. Exchange Online déjà connecté), elle est réutilisée.
    #>
    [CmdletBinding()]
    param()

    if ('Microsoft.Identity.Client.PublicClientApplicationBuilder' -as [type]) {
        return
    }

    Assert-EESPrerequisites -Require Graph

    $module = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' |
        Where-Object { $_.Version -ge $script:EESConstants.MinGraphAuthVersion } |
        Sort-Object -Property Version -Descending | Select-Object -First 1

    $allDlls = Get-ChildItem -LiteralPath $module.ModuleBase -Recurse -Filter '*.dll' -File
    $abstractions = $allDlls | Where-Object { $_.Name -eq 'Microsoft.IdentityModel.Abstractions.dll' } | Select-Object -First 1
    # Préférence pour la build .NET Core (dossier « Core »), sinon toute autre build hors .NET Framework.
    $msal = $allDlls | Where-Object { $_.Name -eq 'Microsoft.Identity.Client.dll' } |
        Sort-Object -Property @{ Expression = { if ($_.DirectoryName -match '[\\/]Core$') { 0 } elseif ($_.DirectoryName -match '[\\/]Desktop$') { 2 } else { 1 } } } |
        Select-Object -First 1

    if (-not $msal) {
        throw "Bibliothèque MSAL introuvable dans $($module.ModuleBase). Réinstallez Microsoft.Graph.Authentication (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force)."
    }

    try {
        if ($abstractions) {
            $alreadyLoaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
                $_.GetName().Name -eq 'Microsoft.IdentityModel.Abstractions' -and
                [System.Runtime.Loader.AssemblyLoadContext]::GetLoadContext($_) -eq [System.Runtime.Loader.AssemblyLoadContext]::Default
            }
            if (-not $alreadyLoaded) {
                $null = [System.Reflection.Assembly]::LoadFrom($abstractions.FullName)
            }
        }
        $null = [System.Reflection.Assembly]::LoadFrom($msal.FullName)
    }
    catch {
        throw "Impossible de charger MSAL depuis $($msal.FullName) : $($_.Exception.Message). Ouvrez une nouvelle session PowerShell 7 et importez EES.MailboxMigration avant ExchangeOnlineManagement."
    }

    if (-not ('Microsoft.Identity.Client.PublicClientApplicationBuilder' -as [type])) {
        throw 'MSAL a été chargé mais ses types sont inaccessibles. Ouvrez une nouvelle session PowerShell 7 et réessayez.'
    }
    Write-EESLog -Level DEBUG -Message "MSAL chargé depuis $($msal.FullName)"
}
