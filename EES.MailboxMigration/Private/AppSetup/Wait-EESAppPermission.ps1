function Wait-EESAppPermission {
    <#
    .SYNOPSIS
        Attend que le certificat et les permissions de l'application soient propagés dans Entra ID.
    .DESCRIPTION
        Juste après la création de l'application, l'obtention d'un jeton peut échouer
        (certificat pas encore reconnu) ou le jeton peut ne pas encore contenir toutes les
        permissions. On réessaie toutes les 15 secondes jusqu'au délai maximal.
    .PARAMETER Role
        Rôle de la connexion.
    .PARAMETER Required
        Permissions requises.
    .PARAMETER TimeoutSec
        Délai maximal d'attente.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [Parameter(Mandatory)]
        [string[]]$Required,

        [int]$TimeoutSec = $script:EESConstants.PermissionWaitTimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastError = $null
    $status = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $status = Test-EESAppPermission -Role $Role -Required $Required -ForceRefresh
            if ($status.IsComplete) {
                return $status
            }
            $lastError = "permissions pas encore visibles : $($status.Missing -join ', ')"
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Write-EESMessage -Message "Propagation en cours dans Entra ID ($lastError). Nouvel essai dans 15 s..."
        Start-Sleep -Seconds 15
    }

    throw "Les permissions de l'application ne sont pas effectives après $TimeoutSec s ($lastError). Relancez Connect-EESTenant -Role $Role dans quelques minutes."
}
