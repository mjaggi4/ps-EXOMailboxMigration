function ConvertTo-EESHtmlReport {
    <#
    .SYNOPSIS
        Produit un rapport HTML autonome (sans ressource externe) à partir des rapports de paires (fonction pure).
    .DESCRIPTION
        Synthèse globale, tableau des boîtes, puis par boîte : détail par dossier (repliable) et
        éléments en échec. Toutes les valeurs sont encodées HTML.
    .PARAMETER Report
        Rapports de paires (Get-EESPairReport).
    .PARAMETER Title
        Titre du rapport.
    .PARAMETER GeneratedAt
        Date de génération.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Report,

        [string]$Title = 'Rapport de migration Exchange Online',

        [datetime]$GeneratedAt = (Get-Date)
    )

    # Encodage des seuls caractères spéciaux HTML (les accents restent lisibles, le fichier est en UTF-8).
    $e = { param($value) ([string]$value).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;') }
    $n = { param($value) if ($null -eq $value -or $value -eq '') { '' } else { '{0:N0}' -f $value } }
    $d = { param($value) if ($value) { '{0:dd/MM/yyyy HH:mm}' -f [datetime]$value } else { '' } }
    $cssClass = {
        param([string]$status)
        switch -Wildcard ($status) {
            'Terminée' { 'ok' }
            '*erreurs*' { 'warn' }
            'En cours*' { 'info' }
            default { 'ko' }
        }
    }

    $totalMigrated = ($Report | Measure-Object -Property ItemsMigrated -Sum).Sum
    $totalFailures = ($Report | Measure-Object -Property PendingFailures -Sum).Sum
    $totalMB = ($Report | Measure-Object -Property LastRunMB -Sum).Sum
    $done = @($Report | Where-Object Status -EQ 'Terminée').Count

    $html = [System.Text.StringBuilder]::new()
    $null = $html.AppendLine('<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">')
    $null = $html.AppendLine("<title>$(& $e $Title)</title>")
    $null = $html.AppendLine(@'
<style>
:root{--bg:#f6f7f9;--card:#fff;--text:#1f2328;--muted:#656d76;--line:#d8dee4;--ok:#1a7f37;--warn:#9a6700;--ko:#cf222e;--info:#0969da}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--text:#e6edf3;--muted:#8d96a0;--line:#30363d;--ok:#3fb950;--warn:#d29922;--ko:#f85149;--info:#58a6ff}}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:1200px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}
.muted{color:var(--muted)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:16px 0}
.tile{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 14px}
.tile b{display:block;font-size:22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 14px;margin:12px 0;overflow-x:auto}
table{border-collapse:collapse;width:100%}
th,td{padding:6px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{font-weight:600;color:var(--muted);white-space:nowrap}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;border:1px solid currentColor}
.ok{color:var(--ok)}.warn{color:var(--warn)}.ko{color:var(--ko)}.info{color:var(--info)}
details summary{cursor:pointer;font-weight:600;margin:6px 0}
</style></head><body><main>
'@)
    $null = $html.AppendLine("<h1>$(& $e $Title)</h1><div class=""muted"">Généré le $(& $d $GeneratedAt) – EES.MailboxMigration</div>")

    $null = $html.AppendLine('<div class="tiles">')
    $null = $html.AppendLine("<div class=""tile""><span class=""muted"">Boîtes</span><b>$($Report.Count)</b></div>")
    $null = $html.AppendLine("<div class=""tile""><span class=""muted"">Terminées sans erreur</span><b>$done</b></div>")
    $null = $html.AppendLine("<div class=""tile""><span class=""muted"">Éléments migrés</span><b>$(& $n $totalMigrated)</b></div>")
    $null = $html.AppendLine("<div class=""tile""><span class=""muted"">Éléments en échec</span><b class=""$(if ($totalFailures) { 'ko' } else { 'ok' })"">$(& $n $totalFailures)</b></div>")
    $null = $html.AppendLine("<div class=""tile""><span class=""muted"">Volume (dernières passes)</span><b>$(& $n $totalMB) Mo</b></div>")
    $null = $html.AppendLine('</div>')

    # Tableau des boîtes.
    $null = $html.AppendLine('<h2>Boîtes</h2><div class="card"><table><thead><tr><th>Source</th><th>Cible</th><th>Type</th><th>Statut</th><th class="num">Migrés</th><th class="num">En échec</th><th>Dernière passe</th><th class="num">Durée</th><th class="num">Débit (Mo/h)</th></tr></thead><tbody>')
    foreach ($r in $Report) {
        $kind = if ($r.IsArchive) { 'Archive' } else { 'Principale' }
        $duration = if ($r.LastRunDuration) { '{0:hh\:mm\:ss}' -f $r.LastRunDuration } else { '' }
        $null = $html.AppendLine(("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><span class=""badge {3}"">{4}</span></td><td class=""num"">{5}</td><td class=""num"">{6}</td><td>{7} ({8})</td><td class=""num"">{9}</td><td class=""num"">{10}</td></tr>" -f `
                    (& $e $r.SourceMailbox), (& $e $r.TargetMailbox), $kind, (& $cssClass $r.Status), (& $e $r.Status),
                (& $n $r.ItemsMigrated), (& $n $r.PendingFailures), (& $d $r.LastRunStart), (& $e $r.LastRunMode), $duration, (& $n $r.ThroughputMBPerHour)))
    }
    $null = $html.AppendLine('</tbody></table></div>')

    # Détail par boîte.
    foreach ($r in $Report) {
        $kind = if ($r.IsArchive) { ' (archive)' } else { '' }
        $null = $html.AppendLine("<h2>$(& $e $r.SourceMailbox) → $(& $e $r.TargetMailbox)$kind</h2><div class=""card"">")
        $null = $html.AppendLine("<details><summary>Dossiers ($(@($r.Folders).Count))</summary><table><thead><tr><th>Dossier source</th><th>Dossier cible</th><th class=""num"">Éléments source</th><th class=""num"">Migrés (cumul)</th><th class=""num"">Copiés</th><th class=""num"">Mis à jour</th><th class=""num"">Déjà présents</th><th class=""num"">Filtrés</th><th class=""num"">En échec</th></tr></thead><tbody>")
        foreach ($f in $r.Folders) {
            $target = if ($f.PSObject.Properties['Excluded'] -and $f.Excluded) { "<span class=""muted"">$(& $e $f.Excluded)</span>" } else { & $e $f.TargetPath }
            $failedClass = if ($f.PendingFailures) { ' ko' } else { '' }
            $null = $html.AppendLine(("<tr><td>{0}</td><td>{1}</td><td class=""num"">{2}</td><td class=""num"">{3}</td><td class=""num"">{4}</td><td class=""num"">{5}</td><td class=""num"">{6}</td><td class=""num"">{7}</td><td class=""num{8}"">{9}</td></tr>" -f `
                        (& $e $f.SourcePath), $target, (& $n $f.SourceItems), (& $n $f.Migrated), (& $n $f.LastRunCopied), (& $n $f.LastRunUpdated),
                    (& $n $f.LastRunSkipped), (& $n $f.LastRunFiltered), $failedClass, (& $n $f.PendingFailures)))
        }
        $null = $html.AppendLine('</tbody></table></details>')

        if (@($r.Failures).Count -gt 0) {
            $null = $html.AppendLine("<details open><summary class=""ko"">Éléments en échec ($(@($r.Failures).Count))</summary><table><thead><tr><th>Dossier</th><th class=""num"">Taille (Ko)</th><th>Erreur</th><th class=""num"">Tentatives</th><th>Identifiant</th></tr></thead><tbody>")
            foreach ($failure in $r.Failures) {
                $null = $html.AppendLine(("<tr><td>{0}</td><td class=""num"">{1}</td><td>{2}</td><td class=""num"">{3}</td><td class=""muted"">{4}</td></tr>" -f `
                            (& $e $failure.FolderPath), (& $n ([math]::Round($failure.SizeBytes / 1KB))), (& $e $failure.Error), $failure.Attempts, (& $e $failure.ItemId)))
            }
            $null = $html.AppendLine('</tbody></table></details>')
        }
        $null = $html.AppendLine('</div>')
    }

    $null = $html.AppendLine('</main></body></html>')
    return $html.ToString()
}
