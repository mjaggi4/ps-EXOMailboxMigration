function Invoke-EESWithReplicationRetry {
    <#
    .SYNOPSIS
        Exécute une opération Entra ID en tolérant les délais de réplication.
    .DESCRIPTION
        Juste après la création d'une application, le service principal ou les attributions de rôles
        peuvent échouer en 400/404 le temps que l'objet soit répliqué. On réessaie quelques fois.
    .PARAMETER ScriptBlock
        Opération à exécuter.
    .PARAMETER Description
        Libellé de l'opération (logs).
    .PARAMETER MaxAttempts
        Nombre maximal d'essais.
    .PARAMETER DelaySeconds
        Délai entre deux essais.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [string]$Description,

        [int]$MaxAttempts = 10,

        [int]$DelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $status = $_.Exception.Data['StatusCode']
            if ($status -notin @(400, 404) -or $attempt -eq $MaxAttempts) {
                throw
            }
            Write-EESLog -Level DEBUG -Message ("{0} : HTTP {1} (réplication Entra ID en cours), essai {2}/{3}." -f $Description, $status, $attempt, $MaxAttempts)
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}
