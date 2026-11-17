function Read-EESInput {
    <#
    .SYNOPSIS
        Lit une saisie de l'administrateur dans le menu (isolée pour les tests).
    .PARAMETER Prompt
        Question affichée.
    .PARAMETER Default
        Valeur retournée si la saisie est vide.
    .PARAMETER Mandatory
        Redemande tant que la saisie est vide.
    .PARAMETER YesNo
        Question oui/non : retourne $true ou $false (« o », « oui », « y », « yes » = oui).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [string]$Default,

        [switch]$Mandatory,

        [switch]$YesNo
    )

    if ($YesNo) {
        $suffix = if ($Default -match '^(?i)o') { ' (O/n)' } else { ' (o/N)' }
        $answer = Read-Host -Prompt "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $answer = $Default
        }
        return [bool]($answer -match '^(?i)(o|oui|y|yes)$')
    }

    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    while ($true) {
        $answer = (Read-Host -Prompt $label).Trim().Trim('"')
        if ($answer) {
            return $answer
        }
        if ($Default) {
            return $Default
        }
        if (-not $Mandatory) {
            return ''
        }
        Write-EESMessage -Type Warning -Message 'Une valeur est obligatoire.'
    }
}
