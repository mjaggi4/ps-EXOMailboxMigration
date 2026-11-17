function Test-EESAzurePstImport {
    <#
    .SYNOPSIS
        Détecte si la fonctionnalité Purview « Azure PST Import » est utilisable.
    .DESCRIPTION
        Annoncée par Microsoft (message MC1455013 : déploiement prévu de fin mars à fin avril 2027),
        cette fonctionnalité 100 % PowerShell n'a pas encore de documentation publique de ses cmdlets.
        Le module ne devine pas de noms de commandes : il recherche, dans la session Exchange Online
        éventuellement ouverte, une commande ou un paramètre « AzurePstImport ». La prise en charge
        complète sera ajoutée quand Microsoft publiera la documentation.
    .OUTPUTS
        { Available, Detected, Message }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $rollout = 'Fonctionnalité annoncée par Microsoft (MC1455013), déploiement prévu de fin mars à fin avril 2027, cmdlets non documentées publiquement à ce jour.'
    $commands = @(Get-Command -Name '*AzurePst*' -ErrorAction SilentlyContinue)
    $endpoint = Get-Command -Name 'New-MigrationEndpoint' -ErrorAction SilentlyContinue
    $parameter = if ($endpoint) { @($endpoint.Parameters.Keys | Where-Object { $_ -like '*AzurePst*' }) } else { @() }

    if ($commands.Count -gt 0 -or $parameter.Count -gt 0) {
        $found = @($commands.Name) + @($parameter | ForEach-Object { "New-MigrationEndpoint -$_" })
        return [pscustomobject]@{
            Available = $false
            Detected  = $true
            Message   = "Azure PST Import semble disponible dans ce tenant ($($found -join ', ')), mais cette version du module ne le prend pas encore en charge. Utilisez -Method NetworkUpload."
        }
    }
    $hint = if (-not $endpoint) { ' (connectez Exchange Online avec Connect-ExchangeOnline pour permettre la détection)' } else { '' }
    return [pscustomobject]@{
        Available = $false
        Detected  = $false
        Message   = "Azure PST Import n'est pas disponible$hint. $rollout Utilisez -Method NetworkUpload."
    }
}
