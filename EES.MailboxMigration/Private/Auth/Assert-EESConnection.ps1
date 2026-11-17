function Assert-EESConnection {
    <#
    .SYNOPSIS
        Vérifie que les rôles demandés sont connectés en mode application.
    .PARAMETER Role
        Rôles requis.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string[]]$Role
    )

    foreach ($r in $Role) {
        $connection = $script:EESConnections[$r]
        if (-not $connection -or -not $connection.ConfidentialClient) {
            throw "Le tenant $r n'est pas connecté. Lancez d'abord : Connect-EESTenant -Role $r"
        }
    }
}
