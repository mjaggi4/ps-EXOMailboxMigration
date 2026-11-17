function Get-EESTenantConfig {
    <#
    .SYNOPSIS
        Lit la configuration persistée des tenants (tenants.json, sans aucun secret).
    .DESCRIPTION
        Contenu par tenant : TenantId, TenantName, DefaultDomain, Roles, AppId, AppObjectId,
        ServicePrincipalId, CertificateThumbprint, CertificateNotAfter, CreatedAt, UpdatedAt.
    .PARAMETER TenantId
        Filtre sur le GUID du tenant ou l'un de ses domaines (DefaultDomain).
    .PARAMETER Role
        Filtre sur le rôle (Source / Target).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$TenantId,

        [ValidateSet('Source', 'Target')]
        [string]$Role
    )

    $path = Join-Path -Path (Get-EESPath -Kind Config) -ChildPath 'tenants.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }

    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
    }
    catch {
        throw "Le fichier de configuration $path est illisible : $($_.Exception.Message)"
    }

    $tenants = @()
    if ($null -ne $data -and $data.PSObject.Properties['Tenants']) {
        $tenants = @($data.Tenants)
    }

    foreach ($tenant in $tenants) {
        if ($TenantId -and -not ($tenant.TenantId -eq $TenantId -or $tenant.DefaultDomain -eq $TenantId)) {
            continue
        }
        if ($Role -and @($tenant.Roles) -notcontains $Role) {
            continue
        }
        $tenant
    }
}
