function Resolve-EESGraphAppRoleId {
    <#
    .SYNOPSIS
        Associe chaque nom de permission applicative à l'identifiant d'appRole de Microsoft Graph.
    .DESCRIPTION
        Les identifiants sont lus dans le tenant (service principal Microsoft Graph) plutôt que
        codés en dur. Lève une erreur claire si une permission n'existe pas (API non déployée).
    .PARAMETER AppRoles
        Collection appRoles du service principal Microsoft Graph.
    .PARAMETER PermissionName
        Noms des permissions applicatives.
    .OUTPUTS
        Dictionnaire ordonné nom -> identifiant.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$AppRoles,

        [Parameter(Mandatory)]
        [string[]]$PermissionName
    )

    $result = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $PermissionName) {
        $appRole = $AppRoles | Where-Object {
            $_.value -eq $name -and @($_.allowedMemberTypes) -contains 'Application'
        } | Select-Object -First 1
        if ($appRole) {
            $result[$name] = [string]$appRole.id
        }
        else {
            $missing.Add($name)
        }
    }

    if ($missing.Count -gt 0) {
        throw ("Permission(s) applicative(s) introuvable(s) dans Microsoft Graph pour ce tenant : {0}. " +
            "Les API mailbox import/export ne sont peut-être pas encore disponibles dans ce tenant.") -f ($missing -join ', ')
    }
    return $result
}
