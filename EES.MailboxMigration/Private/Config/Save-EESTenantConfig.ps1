function Save-EESTenantConfig {
    <#
    .SYNOPSIS
        Ajoute ou met à jour la configuration d'un tenant dans tenants.json.
    .DESCRIPTION
        L'enregistrement est identifié par TenantId. Écriture atomique (fichier temporaire puis
        remplacement). Aucun secret n'est stocké : seulement l'empreinte du certificat.
    .PARAMETER InputObject
        Configuration du tenant (doit contenir TenantId).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$InputObject
    )

    if (-not $InputObject.TenantId) {
        throw 'La configuration à enregistrer doit contenir TenantId.'
    }

    $path = Join-Path -Path (Get-EESPath -Kind Config) -ChildPath 'tenants.json'
    $others = @(Get-EESTenantConfig | Where-Object { $_.TenantId -ne $InputObject.TenantId })

    $InputObject | Add-Member -NotePropertyName 'UpdatedAt' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $all = @($others) + @($InputObject) | Sort-Object -Property TenantName, TenantId

    $document = [ordered]@{
        SchemaVersion = 1
        Tenants       = @($all)
    }
    $json = ConvertTo-Json -InputObject $document -Depth 10

    $tempPath = "$path.tmp"
    Set-Content -LiteralPath $tempPath -Value $json -Encoding utf8NoBOM
    Move-Item -LiteralPath $tempPath -Destination $path -Force
    Write-EESLog -Message "Configuration enregistrée pour le tenant $($InputObject.TenantId)."
}
