function Merge-EESRequiredResourceAccess {
    <#
    .SYNOPSIS
        Ajoute des permissions applicatives à la propriété requiredResourceAccess d'une application.
    .DESCRIPTION
        Fonction pure : conserve les permissions existantes (y compris celles d'autres API),
        ajoute uniquement les permissions manquantes et indique si une mise à jour est nécessaire.
    .PARAMETER Existing
        Valeur actuelle de requiredResourceAccess.
    .PARAMETER ResourceAppId
        AppId de l'API (Microsoft Graph).
    .PARAMETER RoleId
        Identifiants de permissions à garantir (appRoles ou scopes délégués).
    .PARAMETER Type
        Role (permission applicative, défaut) ou Scope (permission déléguée).
    .OUTPUTS
        Objet { Changed, RequiredResourceAccess }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Existing,

        [Parameter(Mandatory)]
        [string]$ResourceAppId,

        [Parameter(Mandatory)]
        [string[]]$RoleId,

        [ValidateSet('Role', 'Scope')]
        [string]$Type = 'Role'
    )

    $output = [System.Collections.Generic.List[object]]::new()
    $found = $false
    $changed = $false

    foreach ($entry in @($Existing | Where-Object { $null -ne $_ })) {
        $access = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($entry.resourceAccess | Where-Object { $null -ne $_ })) {
            $access.Add([ordered]@{ id = [string]$item.id; type = [string]$item.type })
        }

        if ($entry.resourceAppId -eq $ResourceAppId) {
            $found = $true
            foreach ($id in $RoleId) {
                $present = $access | Where-Object { $_.id -eq $id -and $_.type -eq $Type }
                if (-not $present) {
                    $access.Add([ordered]@{ id = $id; type = $Type })
                    $changed = $true
                }
            }
        }
        $output.Add([ordered]@{ resourceAppId = [string]$entry.resourceAppId; resourceAccess = $access.ToArray() })
    }

    if (-not $found) {
        $access = foreach ($id in $RoleId) { [ordered]@{ id = $id; type = $Type } }
        $output.Add([ordered]@{ resourceAppId = $ResourceAppId; resourceAccess = @($access) })
        $changed = $true
    }

    return [pscustomobject]@{
        Changed                = $changed
        RequiredResourceAccess = $output.ToArray()
    }
}
