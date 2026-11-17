function Write-EESMessage {
    <#
    .SYNOPSIS
        Affiche un message destiné à l'administrateur (console), en couleur.
    .DESCRIPTION
        Utilise $Host.UI pour l'affichage interactif ; le message est aussi journalisé (INFO).
        Ne rien afficher de sensible (jeton, URL SAS...).
    .PARAMETER Message
        Texte à afficher.
    .PARAMETER Type
        Info, Success, Warning, Title.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Title')]
        [string]$Type = 'Info'
    )

    process {
        $color = switch ($Type) {
            'Success' { [System.ConsoleColor]::Green }
            'Warning' { [System.ConsoleColor]::Yellow }
            'Title' { [System.ConsoleColor]::Cyan }
            default { [System.ConsoleColor]::Gray }
        }

        if ($Host -and $Host.UI) {
            $Host.UI.WriteLine($color, $Host.UI.RawUI.BackgroundColor, $Message)
        }
        if ($Message) {
            $level = if ($Type -eq 'Warning') { 'WARN' } else { 'INFO' }
            # Pas de double affichage : on écrit seulement dans le fichier log.
            Write-EESLog -Level $level -Message $Message -WarningAction SilentlyContinue -Verbose:$false
        }
    }
}
