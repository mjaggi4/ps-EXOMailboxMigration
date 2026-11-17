BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive

    $script:Source = [pscustomobject]@{ Identity = 'sync@s.com'; MailboxId = 'MBX:s@s'; ApiVersion = 'v1.0'; IsArchive = $false }
    $script:Target = [pscustomobject]@{ Identity = 'sync@t.com'; MailboxId = 'MBX:t@t'; ApiVersion = 'v1.0'; IsArchive = $false }

    $module = 'EES.MailboxMigration'
    # Les corps de mocks s'exécutent hors du module : on précalcule les arborescences.
    $script:SourceTree = InModuleScope $module {
        ConvertTo-EESFolderTree -Folder @(
            [pscustomobject]@{ id = 'S-IN'; displayName = 'Boîte de réception'; parentFolderId = 'R'; wellKnownName = 'inbox'; type = 'IPF.Note'; totalItemCount = 3 }
        )
    }
    $script:TargetTree = InModuleScope $module {
        ConvertTo-EESFolderTree -Folder @(
            [pscustomobject]@{ id = 'T-IN'; displayName = 'Inbox'; parentFolderId = 'R'; wellKnownName = 'inbox'; type = 'IPF.Note'; totalItemCount = 0 }
        )
    }
    Mock -ModuleName $module Get-EESMailboxFolderTree -ParameterFilter { $Role -eq 'Source' } { $script:SourceTree }
    Mock -ModuleName $module Get-EESMailboxFolderTree -ParameterFilter { $Role -eq 'Target' } { $script:TargetTree }
    Mock -ModuleName $module Invoke-EESGraphRequest -ParameterFilter { $Uri -like '*/items/delta*' -and $Uri -notlike '*deltatoken*' } {
        [pscustomobject]@{
            value              = @(
                [pscustomobject]@{ id = 'm1'; changeKey = 'a'; size = 10; createdDateTime = '2025-01-01T00:00:00Z' }
                [pscustomobject]@{ id = 'm2'; changeKey = 'a'; size = 20; createdDateTime = '2025-01-02T00:00:00Z' }
                [pscustomobject]@{ id = 'm3'; changeKey = 'a'; size = 30; createdDateTime = '2025-01-03T00:00:00Z' }
            )
            '@odata.deltaLink' = 'https://graph.microsoft.com/v1.0/x/items/delta?$deltatoken=T1'
        }
    }
    Mock -ModuleName $module Invoke-EESGraphRequest -ParameterFilter { $Uri -like '*deltatoken=T1*' } {
        [pscustomobject]@{
            value              = @([pscustomobject]@{ id = 'm4'; changeKey = 'a'; size = 40; createdDateTime = '2025-02-01T00:00:00Z' })
            '@odata.deltaLink' = 'https://graph.microsoft.com/v1.0/x/items/delta?$deltatoken=T2'
        }
    }
    Mock -ModuleName $module Invoke-EESItemTransfer {
        $journal = foreach ($w in $Work) {
            $Stats[$w.SourceFolderId].Copied++
            [pscustomobject]@{ SourceItemId = $w.SourceItemId; TargetItemId = "t-$($w.SourceItemId)"; SourceChangeKey = 'a'; TargetChangeKey = 'x'; TargetMailboxId = 'M'; SourceFolderId = $w.SourceFolderId }
        }
        & (Get-Module EES.MailboxMigration) { param($s, $j) Add-EESItemJournal -State $s -Entry $j } $State @($journal)
    }
}

Describe 'Invoke-EESMailboxSync' {
    It 'refuse le mode incrémental sans passe complète' {
        InModuleScope EES.MailboxMigration -Parameters @{ Source = $script:Source } {
            { Invoke-EESMailboxSync -SourceMailbox $Source -TargetMailbox ([pscustomobject]@{ Identity = 'autre@t.com'; MailboxId = 'x'; ApiVersion = 'v1.0' }) -Incremental } |
                Should -Throw -ExpectedMessage '*aucune passe complète*'
        }
    }

    It 'copie tout à la première passe' {
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Source = $script:Source; Target = $script:Target } {
            Invoke-EESMailboxSync -SourceMailbox $Source -TargetMailbox $Target
        }
        $result.Status | Should -Be 'Completed'
        $result.Mode | Should -Be 'Full'
        $result.Copied | Should -Be 3
        $result.Folders[0].TargetPath | Should -Be 'Inbox'
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESItemTransfer -Times 1 -Exactly -ParameterFilter { $Work.Count -eq 3 -and $Work[0].FolderId -eq 'T-IN' }
        Test-Path (Join-Path $result.StatePath 'last-run.json') | Should -BeTrue
    }

    It 'ne copie que les nouveautés lors de la passe incrémentale (jeton delta)' {
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Source = $script:Source; Target = $script:Target } {
            Invoke-EESMailboxSync -SourceMailbox $Source -TargetMailbox $Target -Incremental
        }
        $result.Status | Should -Be 'Completed'
        $result.Mode | Should -Be 'Incremental'
        $result.Copied | Should -Be 1
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESItemTransfer -Times 1 -Exactly -ParameterFilter { $Work.Count -eq 1 -and $Work[0].SourceItemId -eq 'm4' }
    }

    It 'ne recopie rien avec -Rescan grâce au journal' {
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Source = $script:Source; Target = $script:Target } {
            Invoke-EESMailboxSync -SourceMailbox $Source -TargetMailbox $Target -Rescan
        }
        $result.Skipped | Should -Be 3
        $result.Copied | Should -Be 0
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESItemTransfer -Times 0 -Exactly
    }

    It 'arrête la migration au-delà de -BadItemLimit et conserve l''état' {
        Mock -ModuleName EES.MailboxMigration Invoke-EESItemTransfer { foreach ($w in $Work) { $Stats[$w.SourceFolderId].Failed++ } }
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Source = $script:Source } {
            $other = [pscustomobject]@{ Identity = 'limit@t.com'; MailboxId = 'MBX:l@l'; ApiVersion = 'v1.0'; IsArchive = $false }
            Invoke-EESMailboxSync -SourceMailbox $Source -TargetMailbox $other -BadItemLimit 2 -WarningAction SilentlyContinue
        }
        $result.Status | Should -Be 'Stopped'
        $result.Message | Should -Match 'BadItemLimit'
        $result.Failed | Should -Be 3
    }

    It 'retourne un statut Failed (sans lever d''erreur) si une API échoue' {
        Mock -ModuleName EES.MailboxMigration Get-EESMailboxFolderTree -ParameterFilter { $Role -eq 'Source' } { throw 'API indisponible' }
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Source = $script:Source } {
            $other = [pscustomobject]@{ Identity = 'fail@t.com'; MailboxId = 'MBX:f@f'; ApiVersion = 'v1.0'; IsArchive = $false }
            Invoke-EESMailboxSync -SourceMailbox $Source -TargetMailbox $other -WarningAction SilentlyContinue
        }
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'API indisponible'
    }
}

Describe 'Start-EESMailboxMigration' {
    It 'exige que les deux tenants soient connectés' {
        InModuleScope EES.MailboxMigration { $script:EESConnections.Clear() }
        { Start-EESMailboxMigration -SourceMailbox a@b.com -TargetMailbox c@d.com } | Should -Throw -ExpectedMessage '*Connect-EESTenant -Role Source*'
    }

    It 'refuse -Incremental avec -Rescan' {
        { Start-EESMailboxMigration a@b.com c@d.com -Incremental -Rescan } | Should -Throw -ExpectedMessage '*-Incremental et -Rescan*'
    }

    It 'affiche le plan des dossiers sans rien copier avec -WhatIf' {
        InModuleScope EES.MailboxMigration {
            foreach ($role in 'Source', 'Target') {
                $script:EESConnections[$role] = [pscustomobject]@{ Role = $role; ConfidentialClient = 'factice' }
            }
        }
        Mock -ModuleName EES.MailboxMigration Resolve-EESMailbox {
            [pscustomobject]@{ Identity = $Identity; MailboxId = "MBX:$Role"; ApiVersion = 'v1.0'; IsArchive = $false }
        }

        Mock -ModuleName EES.MailboxMigration Invoke-EESMailboxSync { throw 'ne doit pas être appelé' }

        $plan = @(Start-EESMailboxMigration a@b.com c@d.com -WhatIf -TargetRootFolder 'Migration')

        $plan.Count | Should -Be 1
        $plan[0].SourcePath | Should -Be 'Boîte de réception'
        $plan[0].TargetPath | Should -Be 'Migration/Boîte de réception'
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESMailboxSync -Times 0 -Exactly
        InModuleScope EES.MailboxMigration { $script:EESConnections.Clear() }
    }
}
