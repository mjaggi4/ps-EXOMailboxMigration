function Connect-EESAdminAccount {
    <#
    .SYNOPSIS
        Connexion interactive de l'administrateur (jeton délégué Microsoft Graph).
    .DESCRIPTION
        Ouvre le navigateur système (flux code d'autorisation + PKCE, géré par MSAL).
        Le client MSAL est conservé par tenant dans $script:EESAdminClients pour les
        acquisitions silencieuses ultérieures.
    .PARAMETER TenantId
        GUID ou domaine du tenant. 'organizations' pour laisser l'administrateur choisir son compte
        (le tenant d'origine du compte est alors utilisé).
    .PARAMETER Scopes
        Permissions déléguées demandées.
    .PARAMETER ClientId
        Client public utilisé pour la connexion.
    .PARAMETER LoginHint
        Compte proposé par défaut.
    .OUTPUTS
        Objet { TenantId, Account, UserPrincipalName, Scopes, ClientId }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string[]]$Scopes,

        [string]$ClientId = $script:EESConstants.AdminClientId,

        [string]$LoginHint
    )

    Initialize-EESMsal

    # Réutilise le client existant (tenant + application cliente) et donc son cache de jetons.
    $client = $script:EESAdminClients["$TenantId|$ClientId"]
    if (-not $client) {
        $authority = '{0}/{1}' -f $script:EESConstants.LoginBaseUrl, $TenantId
        $clientBuilder = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($ClientId)
        $clientBuilder = $clientBuilder.WithAuthority($authority)
        $clientBuilder = $clientBuilder.WithRedirectUri('http://localhost')
        $client = $clientBuilder.Build()
    }

    Write-EESMessage -Message 'Ouverture du navigateur pour la connexion administrateur (délai maximal : 5 minutes)...'

    $builder = $client.AcquireTokenInteractive([string[]]$Scopes).WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
    if ($LoginHint) {
        $builder = $builder.WithLoginHint($LoginHint)
    }

    $cancellation = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(5))
    try {
        $result = $builder.ExecuteAsync($cancellation.Token).GetAwaiter().GetResult()
    }
    catch {
        $inner = Get-EESMsalBaseException -Exception $_.Exception
        throw "Connexion administrateur impossible : $($inner.Message)"
    }
    finally {
        $cancellation.Dispose()
    }

    $resolvedTenantId = $result.TenantId
    $clientKey = "$resolvedTenantId|$ClientId"
    $script:EESAdminClients[$clientKey] = $client
    Write-EESLog -Message ("Compte connecté : {0} (tenant {1})" -f $result.Account.Username, $resolvedTenantId)

    return [pscustomobject]@{
        TenantId          = $resolvedTenantId
        Account           = $result.Account
        UserPrincipalName = $result.Account.Username
        Scopes            = $Scopes
        ClientId          = $ClientId
        ClientKey         = $clientKey
    }
}
