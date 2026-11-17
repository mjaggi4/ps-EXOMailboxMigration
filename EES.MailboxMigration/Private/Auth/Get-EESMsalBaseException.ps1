function Get-EESMsalBaseException {
    <#
    .SYNOPSIS
        Retourne l'exception MSAL d'origine (les appels .NET synchrones l'enveloppent).
    .PARAMETER Exception
        Exception reçue dans un bloc catch.
    #>
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current.GetType().FullName -like 'Microsoft.Identity.Client.*') {
            return $current
        }
        $current = $current.InnerException
    }
    return $Exception.GetBaseException()
}
