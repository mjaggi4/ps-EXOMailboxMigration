function Merge-EESGrantScope {
    <#
    .SYNOPSIS
        Fusionne des permissions déléguées dans la chaîne « scope » d'un oauth2PermissionGrant (fonction pure).
    .PARAMETER Current
        Chaîne actuelle (permissions séparées par des espaces), éventuellement vide.
    .PARAMETER Required
        Permissions à garantir.
    .OUTPUTS
        { Changed, Scope }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Current,

        [Parameter(Mandatory)]
        [string[]]$Required
    )

    $existing = @(([string]$Current).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
    $missing = @($Required | Where-Object { $existing -notcontains $_ })
    return [pscustomobject]@{
        Changed = ($missing.Count -gt 0)
        Scope   = (@($existing) + @($missing)) -join ' '
    }
}
