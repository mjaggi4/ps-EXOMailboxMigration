function Test-EESAppPermission {
    <#
    .SYNOPSIS
        Compare les permissions présentes dans le jeton app-only aux permissions requises.
    .PARAMETER Role
        Rôle de la connexion.
    .PARAMETER Required
        Permissions requises (défaut : celles des rôles enregistrés pour ce tenant).
    .PARAMETER ForceRefresh
        Demande un nouveau jeton (utile juste après un consentement).
    .OUTPUTS
        Objet { IsComplete, Granted, Missing }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [string[]]$Required,

        [switch]$ForceRefresh
    )

    if (-not $Required) {
        $Required = Get-EESRequiredPermission -Role $Role
    }

    $token = Get-EESAccessToken -Role $Role -ForceRefresh:$ForceRefresh
    $claims = ConvertFrom-EESJwt -Token $token
    $granted = @()
    if ($claims.PSObject.Properties['roles']) {
        $granted = @($claims.roles)
    }
    $missing = @($Required | Where-Object { $granted -notcontains $_ })

    return [pscustomobject]@{
        IsComplete = ($missing.Count -eq 0)
        Granted    = [string[]]$granted
        Missing    = [string[]]$missing
    }
}
