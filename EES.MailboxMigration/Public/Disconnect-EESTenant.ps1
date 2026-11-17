function Disconnect-EESTenant {
    <#
    .SYNOPSIS
        Ferme la connexion à un tenant (ou aux deux) dans la session PowerShell.

    .DESCRIPTION
        Supprime de la mémoire les contextes de connexion et les jetons en cache.
        Ne modifie rien dans les tenants : l'application et le certificat sont conservés
        (voir Remove-EESTenantApp pour les supprimer).

    .PARAMETER Role
        Rôle(s) à déconnecter. Par défaut : Source et Target.

    .EXAMPLE
        Disconnect-EESTenant

        Déconnecte les deux tenants.

    .EXAMPLE
        Disconnect-EESTenant -Role Source

        Déconnecte uniquement le tenant source.

    .LINK
        Connect-EESTenant
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [ValidateSet('Source', 'Target')]
        [string[]]$Role = @('Source', 'Target')
    )

    foreach ($currentRole in $Role) {
        $connection = $script:EESConnections[$currentRole]
        if (-not $connection) {
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("$currentRole : $($connection.TenantName)", 'Fermer la connexion')) {
            continue
        }

        $script:EESConnections.Remove($currentRole)

        # Purge du cache du compte administrateur si plus aucun rôle n'utilise ce tenant.
        $stillUsed = $script:EESConnections.Values | Where-Object { $_.TenantId -eq $connection.TenantId }
        if (-not $stillUsed) {
            Clear-EESAdminClient -TenantId $connection.TenantId
        }
        Write-EESMessage -Message "Tenant $currentRole déconnecté ($($connection.TenantName))."
    }
}
