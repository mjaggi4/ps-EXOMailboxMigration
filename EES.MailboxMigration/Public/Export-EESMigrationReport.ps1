function Export-EESMigrationReport {
    <#
    .SYNOPSIS
        Exporte le rapport des migrations en HTML et en CSV.

    .DESCRIPTION
        Fichiers produits (horodatés) :
          - Rapport_<date>.html          : rapport lisible (synthèse, boîtes, dossiers, échecs) ;
          - Rapport_<date>_Boites.csv    : une ligne par boîte (statut, éléments migrés, échecs, durée, débit) ;
          - Rapport_<date>_Dossiers.csv  : une ligne par dossier (éléments source, migrés, copiés, ignorés, en échec) ;
          - Rapport_<date>_Echecs.csv    : une ligne par élément en échec (dossier, taille, erreur).
        Les CSV utilisent le séparateur « ; » et l'UTF-8 avec BOM (ouverture directe dans Excel).
        Peut être lancé pendant une migration (photo de l'avancement).

    .PARAMETER Path
        Dossier de destination. Par défaut : dossier Reports du dossier de travail.

    .PARAMETER Format
        Html, Csv ou les deux (défaut).

    .PARAMETER SourceMailbox
        Filtre sur la boîte source (jokers acceptés).

    .PARAMETER Open
        Ouvre le rapport HTML à la fin.

    .EXAMPLE
        Export-EESMigrationReport -Open

        Génère le rapport HTML et les CSV, puis ouvre le HTML.

    .EXAMPLE
        Export-EESMigrationReport -Path C:\Migration\Rapports -Format Csv

        Génère uniquement les CSV dans le dossier indiqué.

    .OUTPUTS
        System.IO.FileInfo (fichiers créés).

    .LINK
        Get-EESMigrationStatus
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [string]$Path,

        [ValidateSet('Html', 'Csv')]
        [string[]]$Format = @('Html', 'Csv'),

        [string]$SourceMailbox = '*',

        [switch]$Open
    )

    $reports = @(Get-EESMigrationStatus -SourceMailbox $SourceMailbox | Sort-Object -Property SourceMailbox, IsArchive)
    if ($reports.Count -eq 0) {
        Write-EESMessage -Type Warning -Message 'Aucune migration à inclure dans le rapport.'
        return
    }

    $directory = if ($Path) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } else { Get-EESPath -Kind Reports }
    $stamp = '{0:yyyyMMdd_HHmmss}' -f (Get-Date)
    $base = Join-Path -Path $directory -ChildPath "Rapport_$stamp"

    if (-not $PSCmdlet.ShouldProcess($directory, "Créer le rapport de migration ($($Format -join ', '))")) {
        return
    }
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }

    $files = [System.Collections.Generic.List[string]]::new()
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)

    if ($Format -contains 'Html') {
        $htmlPath = "$base.html"
        [System.IO.File]::WriteAllText($htmlPath, (ConvertTo-EESHtmlReport -Report $reports), $utf8Bom)
        $files.Add($htmlPath)
    }

    if ($Format -contains 'Csv') {
        $writeCsv = {
            param([string]$file, [object[]]$rows)
            $lines = @($rows | ConvertTo-Csv -Delimiter ';' -NoTypeInformation)
            [System.IO.File]::WriteAllLines($file, [string[]]$lines, $utf8Bom)
            $files.Add($file)
        }

        $mailboxRows = foreach ($r in $reports) {
            [pscustomobject][ordered]@{
                BoiteSource          = $r.SourceMailbox
                BoiteCible           = $r.TargetMailbox
                Archive              = $r.IsArchive
                Statut               = $r.Status
                ElementsMigres       = $r.ItemsMigrated
                ElementsEnEchec      = $r.PendingFailures
                Passes               = $r.Runs
                DernierePasseMode    = $r.LastRunMode
                DernierePasseDebut   = $r.LastRunStart
                DernierePasseFin     = $r.LastRunEnd
                DernierePasseCopies  = $r.LastRunCopied
                DernierePasseDuree   = if ($r.LastRunDuration) { '{0:hh\:mm\:ss}' -f $r.LastRunDuration } else { $null }
                DernierePasseMo      = $r.LastRunMB
                DebitMoParHeure      = $r.ThroughputMBPerHour
                Dossiers             = $r.FolderCount
            }
        }
        & $writeCsv "$($base)_Boites.csv" @($mailboxRows)

        $folderRows = foreach ($r in $reports) {
            foreach ($f in $r.Folders) {
                [pscustomobject][ordered]@{
                    BoiteSource     = $r.SourceMailbox
                    BoiteCible      = $r.TargetMailbox
                    Archive         = $r.IsArchive
                    DossierSource   = $f.SourcePath
                    DossierCible    = $f.TargetPath
                    ElementsSource  = $f.SourceItems
                    MigresCumul     = $f.Migrated
                    Copies          = $f.LastRunCopied
                    MisAJour        = $f.LastRunUpdated
                    DejaPresents    = $f.LastRunSkipped
                    Filtres         = $f.LastRunFiltered
                    EnEchec         = $f.PendingFailures
                    Exclu           = if ($f.PSObject.Properties['Excluded']) { $f.Excluded } else { $null }
                }
            }
        }
        & $writeCsv "$($base)_Dossiers.csv" @($folderRows)

        $failureRows = foreach ($r in $reports) {
            foreach ($failure in $r.Failures) {
                [pscustomobject][ordered]@{
                    BoiteSource  = $r.SourceMailbox
                    BoiteCible   = $r.TargetMailbox
                    Archive      = $r.IsArchive
                    Dossier      = $failure.FolderPath
                    TailleOctets = $failure.SizeBytes
                    Erreur       = $failure.Error
                    Tentatives   = $failure.Attempts
                    Identifiant  = $failure.ItemId
                }
            }
        }
        if (@($failureRows).Count -gt 0) {
            & $writeCsv "$($base)_Echecs.csv" @($failureRows)
        }
    }

    Write-EESMessage -Type Success -Message "Rapport généré dans $directory"
    if ($Open -and $Format -contains 'Html' -and $IsWindows) {
        Invoke-Item -LiteralPath "$base.html"
    }
    foreach ($file in $files) {
        Get-Item -LiteralPath $file
    }
}
