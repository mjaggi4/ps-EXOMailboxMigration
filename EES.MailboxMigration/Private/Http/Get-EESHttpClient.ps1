function Get-EESHttpClient {
    <#
    .SYNOPSIS
        Retourne le client HTTP partagé utilisé pour les imports concurrents.
    .DESCRIPTION
        Un seul HttpClient par session (réutilisation des connexions). Délai maximal : 30 minutes
        par requête (éléments volumineux).
    #>
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpClient])]
    param()

    if (-not $script:EESHttpClient) {
        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.PooledConnectionLifetime = [TimeSpan]::FromMinutes(10)
        $handler.MaxConnectionsPerServer = 16
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromMinutes(30)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('EES.MailboxMigration/1.0')
        $script:EESHttpClient = $client
    }
    return $script:EESHttpClient
}
