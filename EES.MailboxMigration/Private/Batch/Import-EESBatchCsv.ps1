function Import-EESBatchCsv {
    <#
    .SYNOPSIS
        Lit et valide (hors ligne) un fichier CSV de migration en lot.
    .DESCRIPTION
        - Encodage UTF-8 (avec ou sans BOM), séparateur « ; » ou « , » détecté automatiquement.
        - Colonnes obligatoires : SourceMailbox, TargetMailbox.
        - Colonnes facultatives : IncludeArchive, TargetRootFolder, StartDate, EndDate,
          IncludeFolders, ExcludeFolders (plusieurs dossiers séparés par « | »).
        - Lignes vides et lignes dont SourceMailbox commence par « # » ignorées.
        - Contrôles : adresses valides, booléens et dates valides, StartDate < EndDate,
          boîte source en double (erreur), boîte cible en double (avertissement).
    .PARAMETER Path
        Chemin du fichier CSV.
    .OUTPUTS
        { Path, Delimiter, Rows, Errors, Warnings, IsValid }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Fichier CSV introuvable : $Path"
    }

    $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    $headerLine = $lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if (-not $headerLine) {
        throw "Le fichier CSV est vide : $Path"
    }
    $semicolons = ($headerLine.ToCharArray() | Where-Object { $_ -eq ';' }).Count
    $commas = ($headerLine.ToCharArray() | Where-Object { $_ -eq ',' }).Count
    $delimiter = if ($commas -gt $semicolons) { ',' } else { ';' }

    $known = @('SourceMailbox', 'TargetMailbox', 'IncludeArchive', 'TargetRootFolder', 'StartDate', 'EndDate', 'IncludeFolders', 'ExcludeFolders')
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Correspondance des en-têtes (casse et espaces ignorés).
    $headers = @($headerLine.Split($delimiter) | ForEach-Object { $_.Trim().Trim('"') })
    $columnMap = @{}
    foreach ($header in $headers) {
        $match = $known | Where-Object { $_ -eq $header.Replace(' ', '') } | Select-Object -First 1
        if ($match) {
            $columnMap[$match] = $header
        }
        elseif ($header) {
            $warnings.Add("Colonne inconnue ignorée : « $header ».")
        }
    }
    foreach ($required in @('SourceMailbox', 'TargetMailbox')) {
        if (-not $columnMap.ContainsKey($required)) {
            $errors.Add("Colonne obligatoire absente : $required (séparateur détecté : « $delimiter »).")
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ Path = $Path; Delimiter = $delimiter; Rows = @(); Errors = $errors.ToArray(); Warnings = $warnings.ToArray(); IsValid = $false }
    }

    $records = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ConvertFrom-Csv -Delimiter $delimiter)
    $emailPattern = '^[^@\s;,]+@[^@\s;,]+\.[^@\s;,]+$'
    $rows = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 1

    $get = {
        param($record, [string]$name)
        if ($columnMap.ContainsKey($name)) {
            $value = $record.($columnMap[$name])
            if ($null -ne $value) {
                return ([string]$value).Trim()
            }
        }
        return ''
    }

    foreach ($record in $records) {
        $lineNumber++
        $source = & $get $record 'SourceMailbox'
        $target = & $get $record 'TargetMailbox'
        if (-not $source -and -not $target) {
            continue
        }
        if ($source.StartsWith('#')) {
            continue
        }

        $rowErrors = [System.Collections.Generic.List[string]]::new()
        if ($source -notmatch $emailPattern) {
            $rowErrors.Add("SourceMailbox invalide « $source »")
        }
        if ($target -notmatch $emailPattern) {
            $rowErrors.Add("TargetMailbox invalide « $target »")
        }

        $archiveText = & $get $record 'IncludeArchive'
        $includeArchive = ConvertTo-EESBoolean -Value $archiveText
        if ($null -eq $includeArchive) {
            $rowErrors.Add("IncludeArchive invalide « $archiveText » (attendu : true/false, oui/non)")
            $includeArchive = $false
        }

        $startText = & $get $record 'StartDate'
        $endText = & $get $record 'EndDate'
        $startDate = ConvertTo-EESDate -Value $startText
        $endDate = ConvertTo-EESDate -Value $endText
        if ($startText -and -not $startDate) {
            $rowErrors.Add("StartDate invalide « $startText » (formats : 2025-01-31 ou 31/01/2025)")
        }
        if ($endText -and -not $endDate) {
            $rowErrors.Add("EndDate invalide « $endText » (formats : 2025-01-31 ou 31/01/2025)")
        }
        if ($startDate -and $endDate -and $startDate -ge $endDate) {
            $rowErrors.Add('StartDate doit être antérieure à EndDate')
        }

        $split = {
            param([string]$text)
            , [string[]]@($text.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }

        foreach ($message in $rowErrors) {
            $errors.Add("Ligne $lineNumber : $message.")
        }

        $rows.Add([pscustomobject]@{
                Line             = $lineNumber
                SourceMailbox    = $source.ToLowerInvariant()
                TargetMailbox    = $target.ToLowerInvariant()
                IncludeArchive   = [bool]$includeArchive
                TargetRootFolder = & $get $record 'TargetRootFolder'
                StartDate        = $startDate
                EndDate          = $endDate
                IncludeFolders   = & $split (& $get $record 'IncludeFolders')
                ExcludeFolders   = & $split (& $get $record 'ExcludeFolders')
                IsValid          = ($rowErrors.Count -eq 0)
            })
    }

    if ($rows.Count -eq 0) {
        $errors.Add('Le fichier ne contient aucune ligne de migration.')
    }

    foreach ($group in ($rows | Group-Object -Property SourceMailbox | Where-Object { $_.Count -gt 1 -and $_.Name })) {
        $errors.Add(("Boîte source en double « {0} » (lignes {1})." -f $group.Name, (($group.Group.Line) -join ', ')))
    }
    foreach ($group in ($rows | Group-Object -Property TargetMailbox | Where-Object { $_.Count -gt 1 -and $_.Name })) {
        $warnings.Add(("Boîte cible utilisée plusieurs fois « {0} » (lignes {1}) : les contenus seront fusionnés." -f $group.Name, (($group.Group.Line) -join ', ')))
    }

    return [pscustomobject]@{
        Path      = $Path
        Delimiter = $delimiter
        Rows      = $rows.ToArray()
        Errors    = $errors.ToArray()
        Warnings  = $warnings.ToArray()
        IsValid   = ($errors.Count -eq 0)
    }
}
