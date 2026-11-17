function New-EESBatchTemplate {
    <#
    .SYNOPSIS
        Crée un fichier CSV modèle pour la migration en lot.

    .DESCRIPTION
        Le modèle (UTF-8, séparateur « ; » pour Excel en français) contient les colonnes :
          - SourceMailbox, TargetMailbox : obligatoires ;
          - IncludeArchive : true/false (ou oui/non) ;
          - TargetRootFolder : dossier racine d'import dans la cible (vide : fusion dans les dossiers existants) ;
          - StartDate, EndDate : 2025-01-31 ou 31/01/2025 ;
          - ExcludeFolders (et IncludeFolders, à ajouter si besoin) : dossiers séparés par « | »,
            ex. deleteditems|junkemail.
        Le séparateur « , » est aussi accepté à la lecture. Les lignes commençant par « # » sont ignorées.

    .PARAMETER Path
        Fichier à créer. Par défaut : .\EES-Lot.csv dans le dossier courant.

    .PARAMETER Force
        Remplace le fichier s'il existe.

    .EXAMPLE
        New-EESBatchTemplate

        Crée .\EES-Lot.csv à compléter dans Excel.

    .EXAMPLE
        New-EESBatchTemplate -Path C:\Migration\lot1.csv

        Crée le modèle à l'emplacement indiqué.

    .OUTPUTS
        System.IO.FileInfo

    .LINK
        Start-EESBatchMigration
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [string]$Path = (Join-Path -Path (Get-Location).Path -ChildPath 'EES-Lot.csv'),

        [switch]$Force
    )

    $template = Join-Path -Path $script:EESModuleRoot -ChildPath 'Templates\BatchTemplate.csv'
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ((Test-Path -LiteralPath $resolved) -and -not $Force) {
        throw "Le fichier existe déjà : $resolved (utilisez -Force pour le remplacer)."
    }
    if (-not $PSCmdlet.ShouldProcess($resolved, 'Créer le modèle CSV de migration en lot')) {
        return
    }

    $directory = Split-Path -Path $resolved -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }
    # UTF-8 avec BOM : Excel affiche correctement les accents.
    $content = [System.IO.File]::ReadAllText($template, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($resolved, $content, [System.Text.UTF8Encoding]::new($true))
    Write-EESMessage -Type Success -Message "Modèle créé : $resolved. Remplacez les lignes d'exemple par vos boîtes, puis lancez Test-EESMigrationReadiness -CsvPath '$resolved'."
    return Get-Item -LiteralPath $resolved
}
