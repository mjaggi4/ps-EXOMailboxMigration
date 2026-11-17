function Invoke-EESMenuAction {
    <#
    .SYNOPSIS
        Exécute une entrée du menu interactif (questions guidées puis commande publique).
    .PARAMETER Choice
        Numéro choisi dans le menu.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Choice
    )

    $show = { param($value) if ($null -ne $value) { $value | Format-List | Out-String -Width 160 | Write-EESMessage } }

    switch ($Choice) {
        '1' {
            $tenant = Read-EESInput -Prompt 'Domaine ou ID du tenant SOURCE (vide : choisir à la connexion)'
            $params = @{ Role = 'Source' }
            if ($tenant) { $params.TenantId = $tenant }
            & $show (Connect-EESTenant @params)
        }
        '2' {
            $tenant = Read-EESInput -Prompt 'Domaine ou ID du tenant CIBLE (vide : choisir à la connexion)'
            $params = @{ Role = 'Target' }
            if ($tenant) { $params.TenantId = $tenant }
            & $show (Connect-EESTenant @params)
        }
        '3' {
            Get-EESConnectionStatus | Format-Table -Property Role, Status, TenantName, DefaultDomain, CertificateExpires -AutoSize | Out-String -Width 160 | Write-EESMessage
        }
        '4' {
            $csv = Read-EESInput -Prompt 'Fichier CSV du lot (vide : vérifier une seule boîte)'
            $results = if ($csv) {
                Test-EESMigrationReadiness -CsvPath $csv
            }
            else {
                $source = Read-EESInput -Prompt 'Boîte source' -Mandatory
                $target = Read-EESInput -Prompt 'Boîte cible' -Mandatory
                $archive = Read-EESInput -Prompt 'Vérifier aussi l''archive ?' -YesNo
                Test-EESMigrationReadiness -SourceMailbox $source -TargetMailbox $target -IncludeArchive:$archive
            }
            foreach ($result in @($results)) {
                Write-EESMessage -Type Title -Message ("{0} → {1} : {2}" -f $result.SourceMailbox, $result.TargetMailbox, $result.Status)
                $result.Checks | Format-Table -Property Check, Status, Detail -AutoSize -Wrap | Out-String -Width 160 | Write-EESMessage
            }
        }
        { $_ -in @('5', '7') } {
            $incremental = ($Choice -eq '7')
            $source = Read-EESInput -Prompt 'Boîte source' -Mandatory
            $target = Read-EESInput -Prompt 'Boîte cible' -Mandatory
            $params = @{ SourceMailbox = $source; TargetMailbox = $target; Incremental = $incremental }
            if (-not $incremental) {
                $params.IncludeArchive = Read-EESInput -Prompt 'Copier aussi l''archive (expérimental) ?' -YesNo
                $root = Read-EESInput -Prompt 'Dossier racine dans la cible (vide : fusion dans les dossiers existants)'
                if ($root) { $params.TargetRootFolder = $root }
                if (Read-EESInput -Prompt 'Afficher d''abord le plan des dossiers ?' -YesNo -Default 'o') {
                    Start-EESMailboxMigration @params -WhatIf | Format-Table -AutoSize | Out-String -Width 160 | Write-EESMessage
                    if (-not (Read-EESInput -Prompt 'Lancer la copie ?' -YesNo)) {
                        return
                    }
                }
            }
            $null = Start-EESMailboxMigration @params -Confirm:$false
        }
        '6' {
            $csv = Read-EESInput -Prompt 'Fichier CSV du lot (vide : créer un modèle)'
            if (-not $csv) {
                $path = Read-EESInput -Prompt 'Emplacement du modèle' -Default (Join-Path (Get-Location).Path 'EES-Lot.csv')
                $null = New-EESBatchTemplate -Path $path
                return
            }
            $throttle = [int](Read-EESInput -Prompt 'Nombre de boîtes en parallèle' -Default '4')
            $incremental = Read-EESInput -Prompt 'Passe incrémentale (avant bascule MX) ?' -YesNo
            Start-EESBatchMigration -CsvPath $csv -WhatIf | Format-Table -AutoSize | Out-String -Width 160 | Write-EESMessage
            if (Read-EESInput -Prompt 'Lancer le lot ?' -YesNo) {
                $null = Start-EESBatchMigration -CsvPath $csv -ThrottleLimit $throttle -Incremental:$incremental -Confirm:$false
            }
        }
        '8' {
            Get-EESMigrationStatus | Format-Table -Property SourceMailbox, TargetMailbox, IsArchive, Status, ItemsMigrated, PendingFailures, LastRunStart -AutoSize | Out-String -Width 180 | Write-EESMessage
            if (Read-EESInput -Prompt 'Générer le rapport HTML et CSV ?' -YesNo -Default 'o') {
                $null = Export-EESMigrationReport -Open -Confirm:$false
            }
        }
        '9' {
            $mailbox = Read-EESInput -Prompt 'Boîte à exporter' -Mandatory
            $output = Read-EESInput -Prompt 'Dossier de destination' -Mandatory
            $role = if (Read-EESInput -Prompt 'La boîte est-elle dans le tenant CIBLE ?' -YesNo) { 'Target' } else { 'Source' }
            $method = if (Read-EESInput -Prompt 'Utiliser Outlook classique au lieu d''eDiscovery ?' -YesNo) { 'Outlook' } else { 'EDiscovery' }
            & $show (Export-EESMailboxToPst -Mailbox $mailbox -OutputPath $output -Role $role -Method $method)
        }
        '10' {
            $pst = Read-EESInput -Prompt 'Fichier PST ou dossier de PST' -Mandatory
            $mailbox = Read-EESInput -Prompt 'Boîte de destination' -Mandatory
            $params = @{ PstPath = $pst; TargetMailbox = $mailbox; Confirm = $false }
            $root = Read-EESInput -Prompt 'Dossier racine dans la boîte (vide : fusion dans les dossiers existants)'
            if ($root) { $params.TargetRootFolder = $root }
            $params.IsArchive = Read-EESInput -Prompt 'Importer dans l''archive ?' -YesNo
            & $show (Import-EESPstToMailbox @params)
        }
        '11' {
            $role = if (Read-EESInput -Prompt 'Supprimer l''application du tenant CIBLE (sinon SOURCE) ?' -YesNo) { 'Target' } else { 'Source' }
            Remove-EESTenantApp -Role $role
        }
        default {
            Write-EESMessage -Type Warning -Message "Choix inconnu : $Choice"
        }
    }
}
