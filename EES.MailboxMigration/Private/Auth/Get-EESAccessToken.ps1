function Get-EESAccessToken {
    <#
    .SYNOPSIS
        Retourne un jeton d'accès pour une connexion (rôle Source / Target ou objet de connexion).
    .DESCRIPTION
        - Par défaut : jeton app-only obtenu avec le certificat de l'application EES-MailboxMigration.
        - -Delegated : jeton délégué de l'administrateur connecté (acquisition silencieuse,
          puis interactive si nécessaire).
        MSAL met les jetons en cache et les renouvelle automatiquement.
    .PARAMETER Role
        Rôle de la connexion.
    .PARAMETER Connection
        Objet de connexion explicite (ex. connexion administrateur temporaire).
    .PARAMETER Delegated
        Jeton délégué de l'administrateur.
    .PARAMETER Resource
        Ressource ciblée en app-only (défaut : Microsoft Graph).
    .PARAMETER Scopes
        Permissions déléguées (défaut : celles demandées à la connexion).
    .PARAMETER ForceRefresh
        Ignore le cache MSAL.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Role')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Role')]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [Parameter(Mandatory, ParameterSetName = 'Connection')]
        [pscustomobject]$Connection,

        [switch]$Delegated,

        [string]$Resource = $script:EESConstants.GraphBaseUrl,

        [string[]]$Scopes,

        [switch]$ForceRefresh
    )

    if ($PSCmdlet.ParameterSetName -eq 'Role') {
        $Connection = $script:EESConnections[$Role]
        if (-not $Connection) {
            throw "Aucune connexion active pour le rôle $Role. Lancez d'abord : Connect-EESTenant -Role $Role"
        }
    }
    $label = $Connection.Role

    if ($Delegated) {
        if (-not $Connection.AdminAccount) {
            throw "Cette opération nécessite la connexion de l'administrateur du tenant ($label). Lancez : Connect-EESTenant -Role $label -Repair"
        }
        $clientKey = if ($Connection.PSObject.Properties['AdminClientKey'] -and $Connection.AdminClientKey) { $Connection.AdminClientKey } else { "$($Connection.TenantId)|$($script:EESConstants.AdminClientId)" }
        $client = $script:EESAdminClients[$clientKey]
        $requestedScopes = if ($Scopes) { $Scopes } else { $Connection.AdminScopes }
        try {
            $silent = $client.AcquireTokenSilent([string[]]$requestedScopes, $Connection.AdminAccount)
            $silent = $silent.WithForceRefresh([bool]$ForceRefresh)
            $result = $silent.ExecuteAsync().GetAwaiter().GetResult()
        }
        catch {
            $inner = Get-EESMsalBaseException -Exception $_.Exception
            if ($inner.GetType().Name -ne 'MsalUiRequiredException') {
                throw "Jeton administrateur indisponible ($label) : $($inner.Message)"
            }
            # Consentement ou authentification supplémentaire requis : nouvelle connexion interactive.
            $clientId = $clientKey.Split('|')[1]
            $admin = Connect-EESAdminAccount -TenantId $Connection.TenantId -Scopes $requestedScopes -LoginHint $Connection.AdminUpn -ClientId $clientId
            $Connection.AdminAccount = $admin.Account
            $client = $script:EESAdminClients[$admin.ClientKey]
            $result = $client.AcquireTokenSilent([string[]]$requestedScopes, $admin.Account).ExecuteAsync().GetAwaiter().GetResult()
        }
        return $result.AccessToken
    }

    if (-not $Connection.ConfidentialClient) {
        throw "L'application du tenant ($label) n'est pas encore configurée. Lancez : Connect-EESTenant -Role $label"
    }
    $appScopes = [string[]]@('{0}/.default' -f $Resource.TrimEnd('/'))
    try {
        $request = $Connection.ConfidentialClient.AcquireTokenForClient($appScopes)
        $request = $request.WithForceRefresh([bool]$ForceRefresh)
        $result = $request.ExecuteAsync().GetAwaiter().GetResult()
    }
    catch {
        $inner = Get-EESMsalBaseException -Exception $_.Exception
        throw "Jeton applicatif indisponible ($label) : $($inner.Message)"
    }
    return $result.AccessToken
}
