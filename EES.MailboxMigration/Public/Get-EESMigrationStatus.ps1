function Get-EESMigrationStatus {
    <#
    .SYNOPSIS
        Affiche l'état des migrations (terminées, en cours ou interrompues).

    .DESCRIPTION
        Lit les dossiers d'état (State) : une ligne par paire de boîtes (et par archive), avec le
        nombre d'éléments déjà migrés (toutes passes confondues), les éléments en échec restant à
        traiter et le résultat de la dernière passe.

        Peut être lancée dans une autre fenêtre PowerShell pendant une migration pour suivre
        l'avancement (le nombre d'éléments migrés augmente au fil de l'eau). Ne nécessite pas
        de connexion aux tenants.

    .PARAMETER SourceMailbox
        Filtre sur la boîte source (jokers acceptés).

    .PARAMETER TargetMailbox
        Filtre sur la boîte cible (jokers acceptés).

    .PARAMETER Detailed
        Ajoute l'affichage du détail par dossier et des éléments en échec.

    .EXAMPLE
        Get-EESMigrationStatus

        Liste toutes les migrations connues sur ce poste.

    .EXAMPLE
        while ($true) { Clear-Host; Get-EESMigrationStatus -SourceMailbox jdupont@* | Format-List; Start-Sleep 60 }

        Suit une migration en cours, rafraîchi toutes les minutes.

    .EXAMPLE
        (Get-EESMigrationStatus -SourceMailbox jdupont@contoso.com).Failures | Format-Table

        Liste les éléments en échec d'une boîte.

    .OUTPUTS
        EES.MigrationStatus

    .LINK
        Export-EESMigrationReport
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$SourceMailbox = '*',

        [string]$TargetMailbox = '*',

        [switch]$Detailed
    )

    $root = Get-EESPath -Kind State
    $directories = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'state.json') })
    if ($directories.Count -eq 0) {
        Write-EESMessage -Message "Aucune migration enregistrée dans $root."
        return
    }

    foreach ($directory in $directories) {
        try {
            $report = Get-EESPairReport -StatePath $directory.FullName
        }
        catch {
            Write-EESLog -Level WARN -Message "État illisible ($($directory.Name)) : $($_.Exception.Message)"
            continue
        }
        if ($report.SourceMailbox -notlike $SourceMailbox -or $report.TargetMailbox -notlike $TargetMailbox) {
            continue
        }
        if ($Detailed) {
            $report.PSObject.TypeNames.Insert(0, 'EES.MigrationStatusDetailed')
        }
        $report
    }
}
