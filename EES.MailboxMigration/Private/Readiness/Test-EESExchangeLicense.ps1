function Test-EESExchangeLicense {
    <#
    .SYNOPSIS
        Indique si un utilisateur dispose d'un plan de service Exchange Online actif (fonction pure).
    .DESCRIPTION
        Analyse la réponse de GET /users/{id}/licenseDetails : un plan EXCHANGE_S_* (hors
        EXCHANGE_S_FOUNDATION, qui ne fournit pas de boîte) avec provisioningStatus = Success.
    .PARAMETER LicenseDetails
        Collection licenseDetails.
    .OUTPUTS
        { HasExchange, Plans, Skus }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$LicenseDetails
    )

    $plans = foreach ($license in $LicenseDetails) {
        foreach ($plan in @($license.servicePlans)) {
            if ($plan.servicePlanName -like 'EXCHANGE_S_*' -and
                $plan.servicePlanName -ne 'EXCHANGE_S_FOUNDATION' -and
                $plan.provisioningStatus -eq 'Success') {
                [string]$plan.servicePlanName
            }
        }
    }
    $plans = @($plans | Sort-Object -Unique)
    return [pscustomobject]@{
        HasExchange = ($plans.Count -gt 0)
        Plans       = [string[]]$plans
        Skus        = [string[]]@($LicenseDetails | ForEach-Object { $_.skuPartNumber } | Where-Object { $_ })
    }
}
