function Clear-EESAdminClient {
    <#
    .SYNOPSIS
        Supprime de la mémoire les clients MSAL interactifs (et leurs jetons) d'un tenant.
    .PARAMETER TenantId
        GUID du tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId
    )

    foreach ($key in @($script:EESAdminClients.Keys | Where-Object { $_ -like "$TenantId|*" })) {
        $client = $script:EESAdminClients[$key]
        try {
            foreach ($account in @($client.GetAccountsAsync().GetAwaiter().GetResult())) {
                $client.RemoveAsync($account).GetAwaiter().GetResult()
            }
        }
        catch {
            Write-EESLog -Level DEBUG -Message "Purge du cache MSAL : $($_.Exception.Message)"
        }
        $script:EESAdminClients.Remove($key)
    }
}
