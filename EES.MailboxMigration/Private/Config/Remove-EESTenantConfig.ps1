function Remove-EESTenantConfig {
    <#
    .SYNOPSIS
        Supprime la configuration d'un tenant de tenants.json.
    .PARAMETER TenantId
        GUID du tenant.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId
    )

    $path = Join-Path -Path (Get-EESPath -Kind Config) -ChildPath 'tenants.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }

    $remaining = @(Get-EESTenantConfig | Where-Object { $_.TenantId -ne $TenantId })
    if ($PSCmdlet.ShouldProcess($path, "Supprimer la configuration du tenant $TenantId")) {
        $document = [ordered]@{
            SchemaVersion = 1
            Tenants       = @($remaining)
        }
        $tempPath = "$path.tmp"
        Set-Content -LiteralPath $tempPath -Value (ConvertTo-Json -InputObject $document -Depth 10) -Encoding utf8NoBOM
        Move-Item -LiteralPath $tempPath -Destination $path -Force
        Write-EESLog -Message "Configuration supprimée pour le tenant $TenantId."
    }
}
