function Get-EESUploadDelay {
    <#
    .SYNOPSIS
        Calcule l'attente nécessaire avant d'envoyer des octets vers une boîte (fonction pure).
    .DESCRIPTION
        Microsoft limite les envois (POST/PUT/PATCH) à 150 Mo par tranche de 5 minutes, par
        application et par boîte (erreur 429 « Application is over its IncomingBytes limit »).
        Cette fonction tient une fenêtre glissante des envois récents et indique combien de
        secondes attendre pour rester sous le budget. Un envoi plus gros que le budget est autorisé
        lorsque la fenêtre est vide.
    .PARAMETER Window
        Liste des envois récents { Time, Bytes } (élaguée en place).
    .PARAMETER Bytes
        Taille de l'envoi prévu.
    .PARAMETER BudgetBytes
        Budget de la fenêtre.
    .PARAMETER WindowSeconds
        Durée de la fenêtre.
    .PARAMETER Now
        Date de référence (tests).
    .OUTPUTS
        Nombre de secondes à attendre (0 : envoi possible immédiatement).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Window,

        [Parameter(Mandatory)]
        [long]$Bytes,

        [long]$BudgetBytes = 140MB,

        [int]$WindowSeconds = 300,

        [datetime]$Now = (Get-Date)
    )

    # Élagage des envois sortis de la fenêtre.
    $limit = $Now.AddSeconds(-$WindowSeconds)
    while ($Window.Count -gt 0 -and $Window[0].Time -le $limit) {
        $Window.RemoveAt(0)
    }
    if ($Window.Count -eq 0) {
        return [double]0
    }

    $used = [long]0
    foreach ($entry in $Window) {
        $used += [long]$entry.Bytes
    }
    if ($used + $Bytes -le $BudgetBytes) {
        return [double]0
    }

    # Attente jusqu'à libération d'assez d'octets (les envois les plus anciens sortent en premier).
    $toFree = $used + $Bytes - $BudgetBytes
    $freed = [long]0
    foreach ($entry in $Window) {
        $freed += [long]$entry.Bytes
        if ($freed -ge $toFree) {
            return [double][math]::Max(1, ($entry.Time.AddSeconds($WindowSeconds) - $Now).TotalSeconds + 1)
        }
    }
    # Envoi plus gros que le budget : attendre que la fenêtre soit vide.
    return [double][math]::Max(1, ($Window[$Window.Count - 1].Time.AddSeconds($WindowSeconds) - $Now).TotalSeconds + 1)
}
