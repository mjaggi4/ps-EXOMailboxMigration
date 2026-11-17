function Get-EESEDiscoveryErrorHint {
    <#
    .SYNOPSIS
        Traduit une erreur eDiscovery en conseil d'action pour l'administrateur (fonction pure).
    .PARAMETER Message
        Message d'erreur.
    .PARAMETER StatusCode
        Code HTTP éventuel.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [object]$StatusCode
    )

    $text = [string]$Message
    if ($text -match '(?i)pay-?as-?you-?go|billing|subscription|factur') {
        return "Les API eDiscovery de Microsoft Graph exigent, pour les licences E3/Business, un abonnement Azure « pay-as-you-go » relié à Microsoft Purview (export facturé au volume). Configurez-le dans le portail Purview (Paramètres > Facturation à l'utilisation), ou utilisez -Method Outlook."
    }
    if ($text -match '(?i)licen') {
        return "La licence du tenant ou de l'utilisateur ne permet pas l'export eDiscovery (Business Standard notamment). Utilisez -Method Outlook."
    }
    if ([string]$StatusCode -eq '403' -or $text -match '(?i)forbidden|not authorized|unauthorized|access denied|role') {
        return "Le compte connecté doit avoir un rôle Purview eDiscovery (groupe de rôles « eDiscovery Manager ») : portail Purview > Paramètres > Rôles et étendues > Groupes de rôles. L'attribution peut prendre jusqu'à une heure."
    }
    if ([string]$StatusCode -eq '401' -or $text -match 'AADSTS') {
        return "Authentification refusée : relancez la commande ; si l'erreur persiste, vérifiez que le consentement administrateur de l'application EES-MailboxMigration est accordé (portail Entra > Applications d'entreprise)."
    }
    return $null
}
