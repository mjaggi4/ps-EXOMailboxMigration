BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive

    # État simulé : 3 éléments migrés, 1 échec, une passe terminée avec erreurs.
    InModuleScope EES.MailboxMigration {
        $path = Get-EESStatePath -SourceIdentity 'jdupont@contoso.com' -TargetIdentity 'jean.dupont@fabrikam.com'
        $state = Read-EESMigrationState -Path $path
        $state.Meta.SourceIdentity = 'jdupont@contoso.com'
        $state.Meta.TargetIdentity = 'jean.dupont@fabrikam.com'
        $state.Meta.IsArchive = $false
        $state.Meta.Runs = 1
        $state.Meta.HasCompletedRun = $true
        $state.Meta.LastRunStart = '2026-11-17T08:00:00Z'
        $state.Meta.LastRunEnd = '2026-11-17T09:00:00Z'
        $state.Folders['F-IN'] = @{ SourcePath = 'Boîte de réception'; TargetPath = 'Inbox'; LastSync = '2026-11-17T08:30:00Z' }
        $state.Folders['F-X'] = @{ SourcePath = 'Projets <script>'; TargetPath = 'Projets <script>' }
        $state.Failures['bad1'] = @{ SourceFolderId = 'F-IN'; FolderPath = 'Boîte de réception'; Size = 2048; Error = 'Import impossible (HTTP 400) : élément <corrompu>'; Attempts = 2; LastAttempt = '2026-11-17T08:40:00Z' }
        Add-EESItemJournal -State $state -Entry @(
            [pscustomobject]@{ SourceItemId = 'a'; TargetItemId = 'ta'; SourceChangeKey = 'c'; TargetChangeKey = 'c'; TargetMailboxId = 'M'; SourceFolderId = 'F-IN' }
            [pscustomobject]@{ SourceItemId = 'b'; TargetItemId = 'tb'; SourceChangeKey = 'c'; TargetChangeKey = 'c'; TargetMailboxId = 'M'; SourceFolderId = 'F-IN' }
            [pscustomobject]@{ SourceItemId = 'c'; TargetItemId = 'tc'; SourceChangeKey = 'c'; TargetChangeKey = 'c'; TargetMailboxId = 'M'; SourceFolderId = 'F-X' }
        )
        Save-EESMigrationState -State $state
        $lastRun = [pscustomobject]@{
            Status = 'CompletedWithErrors'; Mode = 'Full'; Copied = 3; Failed = 1; BytesCopied = 3MB; ThroughputMBPerHour = 3
            Duration = [TimeSpan]::FromMinutes(60)
            Folders = @(
                [pscustomobject]@{ SourcePath = 'Boîte de réception'; SourceItems = 3; Copied = 2; Updated = 0; Skipped = 0; Filtered = 0; Failed = 1; Bytes = 2MB; Status = 'Terminé avec erreurs' }
                [pscustomobject]@{ SourcePath = 'Projets <script>'; SourceItems = 1; Copied = 1; Updated = 0; Skipped = 0; Filtered = 0; Failed = 0; Bytes = 1MB; Status = 'Terminé' }
                [pscustomobject]@{ SourcePath = 'Problèmes de synchronisation'; SourceItems = 5; Copied = 0; Updated = 0; Skipped = 0; Filtered = 0; Failed = 0; Bytes = 0; Status = 'Exclu (Dossier système (syncissues))' }
            )
        }
        Write-EESAtomicFile -Path (Join-Path $path 'last-run.json') -Content (ConvertTo-Json -InputObject $lastRun -Depth 6)
    }
}

Describe 'Get-EESMigrationStatus' {
    It 'résume l''état d''une paire de boîtes' {
        $status = @(Get-EESMigrationStatus)
        $status.Count | Should -Be 1
        $status[0].SourceMailbox | Should -Be 'jdupont@contoso.com'
        $status[0].Status | Should -Be 'Terminée avec erreurs'
        $status[0].ItemsMigrated | Should -Be 3
        $status[0].PendingFailures | Should -Be 1
        $status[0].LastRunDuration.TotalMinutes | Should -Be 60
    }

    It 'compte les éléments migrés par dossier et inclut les dossiers exclus' {
        $status = Get-EESMigrationStatus -SourceMailbox 'jdupont@*'
        $inbox = $status.Folders | Where-Object SourcePath -EQ 'Boîte de réception'
        $inbox.Migrated | Should -Be 2
        $inbox.PendingFailures | Should -Be 1
        $inbox.SourceItems | Should -Be 3
        ($status.Folders | Where-Object SourcePath -EQ 'Problèmes de synchronisation').Excluded | Should -Match 'Exclu'
    }

    It 'filtre par boîte source' {
        @(Get-EESMigrationStatus -SourceMailbox 'autre@*').Count | Should -Be 0
    }

    It 'indique une passe en cours (début postérieur à la dernière fin)' {
        InModuleScope EES.MailboxMigration {
            $path = Get-EESStatePath -SourceIdentity 'encours@contoso.com' -TargetIdentity 'encours@fabrikam.com'
            $state = Read-EESMigrationState -Path $path
            $state.Meta.SourceIdentity = 'encours@contoso.com'
            $state.Meta.TargetIdentity = 'encours@fabrikam.com'
            $state.Meta.LastRunStart = '2026-11-17T10:00:00Z'
            $state.Meta.LastRunEnd = '2026-11-16T10:00:00Z'
            Save-EESMigrationState -State $state
        }
        (Get-EESMigrationStatus -SourceMailbox 'encours@*').Status | Should -Be 'En cours (ou interrompue)'
    }
}

Describe 'Export-EESMigrationReport' {
    It 'produit le HTML et les CSV (séparateur ; et BOM)' {
        $out = Join-Path $TestDrive 'rapports'
        $files = @(Export-EESMigrationReport -Path $out -SourceMailbox 'jdupont@*')

        $files.Name | Should -Contain ($files | Where-Object Extension -EQ '.html').Name
        $boites = $files | Where-Object Name -Like '*_Boites.csv'
        $dossiers = $files | Where-Object Name -Like '*_Dossiers.csv'
        $echecs = $files | Where-Object Name -Like '*_Echecs.csv'
        $boites | Should -Not -BeNullOrEmpty
        $echecs | Should -Not -BeNullOrEmpty

        [System.IO.File]::ReadAllBytes($boites.FullName)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $rows = Import-Csv -LiteralPath $dossiers.FullName -Delimiter ';' -Encoding utf8
        ($rows | Where-Object DossierSource -EQ 'Boîte de réception').MigresCumul | Should -Be '2'
        (Import-Csv -LiteralPath $echecs.FullName -Delimiter ';' -Encoding utf8).Erreur | Should -Match 'corrompu'
    }

    It 'encode les valeurs dans le HTML' {
        $out = Join-Path $TestDrive 'rapports-html'
        $html = Export-EESMigrationReport -Path $out -Format Html -SourceMailbox 'jdupont@*'
        $content = Get-Content -LiteralPath $html.FullName -Raw
        $content | Should -Match 'Projets &lt;script&gt;'
        $content | Should -Not -Match '<script>'
        $content | Should -Match 'élément &lt;corrompu&gt;'
        $content | Should -Match 'Terminée avec erreurs'
    }

    It 'ne crée rien avec -WhatIf' {
        $out = Join-Path $TestDrive 'rapports-whatif'
        Export-EESMigrationReport -Path $out -WhatIf
        Test-Path -LiteralPath $out | Should -BeFalse
    }
}
