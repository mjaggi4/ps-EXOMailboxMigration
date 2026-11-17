BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive

    # Boîte source en français, boîte cible en anglais.
    $script:SourceRaw = @(
        [pscustomobject]@{ id = 'S-IN'; displayName = 'Boîte de réception'; parentFolderId = 'S-ROOT'; wellKnownName = 'inbox'; type = 'IPF.Note'; totalItemCount = 10 }
        [pscustomobject]@{ id = 'S-PRJ'; displayName = 'Projets'; parentFolderId = 'S-IN'; wellKnownName = $null; type = 'IPF.Note'; totalItemCount = 3 }
        [pscustomobject]@{ id = 'S-PRJ2'; displayName = '2024'; parentFolderId = 'S-PRJ'; wellKnownName = $null; type = 'IPF.Note'; totalItemCount = 1 }
        [pscustomobject]@{ id = 'S-SENT'; displayName = 'Éléments envoyés'; parentFolderId = 'S-ROOT'; wellKnownName = 'sentitems'; type = 'IPF.Note'; totalItemCount = 5 }
        [pscustomobject]@{ id = 'S-CAL'; displayName = 'Calendrier'; parentFolderId = 'S-ROOT'; wellKnownName = 'calendar'; type = 'IPF.Appointment'; totalItemCount = 7 }
        [pscustomobject]@{ id = 'S-PERSO'; displayName = 'Perso'; parentFolderId = 'S-ROOT'; wellKnownName = $null; type = 'IPF.Note'; totalItemCount = 2 }
        [pscustomobject]@{ id = 'S-SYNC'; displayName = 'Problèmes de synchronisation'; parentFolderId = 'S-ROOT'; wellKnownName = 'syncissues'; type = 'IPF.Note'; totalItemCount = 4 }
        [pscustomobject]@{ id = 'S-CONF'; displayName = 'Conflits'; parentFolderId = 'S-SYNC'; wellKnownName = 'conflicts'; type = 'IPF.Note'; totalItemCount = 1 }
        [pscustomobject]@{ id = 'S-DEL'; displayName = 'Éléments supprimés'; parentFolderId = 'S-ROOT'; wellKnownName = 'deleteditems'; type = 'IPF.Note'; totalItemCount = 9 }
        [pscustomobject]@{ id = 'S-SLASH'; displayName = 'A/B'; parentFolderId = 'S-ROOT'; wellKnownName = $null; type = 'IPF.Note'; totalItemCount = 0 }
    )
    $script:TargetRaw = @(
        [pscustomobject]@{ id = 'T-IN'; displayName = 'Inbox'; parentFolderId = 'T-ROOT'; wellKnownName = 'inbox'; type = 'IPF.Note'; totalItemCount = 0 }
        [pscustomobject]@{ id = 'T-SENT'; displayName = 'Sent Items'; parentFolderId = 'T-ROOT'; wellKnownName = 'sentitems'; type = 'IPF.Note'; totalItemCount = 0 }
        [pscustomobject]@{ id = 'T-CAL'; displayName = 'Calendar'; parentFolderId = 'T-ROOT'; wellKnownName = 'calendar'; type = 'IPF.Appointment'; totalItemCount = 0 }
        [pscustomobject]@{ id = 'T-DEL'; displayName = 'Deleted Items'; parentFolderId = 'T-ROOT'; wellKnownName = 'deleteditems'; type = 'IPF.Note'; totalItemCount = 0 }
        [pscustomobject]@{ id = 'T-PERSO'; displayName = 'perso'; parentFolderId = 'T-ROOT'; wellKnownName = $null; type = 'IPF.Note'; totalItemCount = 0 }
    )
}

Describe 'ConvertTo-EESFolderTree' {
    It 'calcule les chemins, l''ancre well-known et le chemin canonique' {
        InModuleScope EES.MailboxMigration -Parameters @{ Raw = $script:SourceRaw } {
            $tree = @(ConvertTo-EESFolderTree -Folder $Raw)
            $sub = $tree | Where-Object Id -EQ 'S-PRJ2'
            $sub.Path | Should -Be 'Boîte de réception/Projets/2024'
            $sub.Anchor | Should -Be 'inbox'
            $sub.Relative | Should -Be @('Projets', '2024')
            $sub.CanonicalPath | Should -Be 'inbox/Projets/2024'
            $sub.Depth | Should -Be 3

            $perso = $tree | Where-Object Id -EQ 'S-PERSO'
            $perso.Anchor | Should -BeNullOrEmpty
            $perso.CanonicalPath | Should -Be 'Perso'
        }
    }

    It 'remplace le « / » d''un nom de dossier pour ne pas casser le chemin' {
        InModuleScope EES.MailboxMigration -Parameters @{ Raw = $script:SourceRaw } {
            $folder = ConvertTo-EESFolderTree -Folder $Raw | Where-Object Id -EQ 'S-SLASH'
            $folder.Segments.Count | Should -Be 1
            $folder.Path | Should -Not -Match '/'
        }
    }

    It 'gère des dossiers fournis dans le désordre (enfant avant parent)' {
        InModuleScope EES.MailboxMigration -Parameters @{ Raw = $script:SourceRaw } {
            $reversed = [object[]]$Raw.Clone()
            [array]::Reverse($reversed)
            $sub = ConvertTo-EESFolderTree -Folder $reversed | Where-Object Id -EQ 'S-PRJ2'
            $sub.Path | Should -Be 'Boîte de réception/Projets/2024'
        }
    }
}

Describe 'Test-EESFolderFilter' {
    BeforeAll {
        $script:Folder = [pscustomobject]@{ Path = 'Boîte de réception/Projets/2024'; CanonicalPath = 'inbox/Projets/2024' }
    }

    It 'correspond au motif <Pattern> : <Expected>' -ForEach @(
        @{ Pattern = 'inbox'; Expected = $true }
        @{ Pattern = 'INBOX/projets'; Expected = $true }
        @{ Pattern = 'Boîte de réception'; Expected = $true }
        @{ Pattern = '\Boîte de réception\Projets\'; Expected = $true }
        @{ Pattern = '*/2024'; Expected = $true }
        @{ Pattern = 'inbox/Proj'; Expected = $false }
        @{ Pattern = 'sentitems'; Expected = $false }
    ) {
        InModuleScope EES.MailboxMigration -Parameters @{ Folder = $script:Folder; Pattern = $Pattern; Expected = $Expected } {
            Test-EESFolderFilter -Folder $Folder -Pattern $Pattern | Should -Be $Expected
        }
    }

    It 'ne correspond à rien sans motif' {
        InModuleScope EES.MailboxMigration -Parameters @{ Folder = $script:Folder } {
            Test-EESFolderFilter -Folder $Folder -Pattern @() | Should -BeFalse
        }
    }
}

Describe 'Get-EESFolderMappingPlan' {
    BeforeAll {
        $script:GetPlan = {
            param([hashtable]$Extra = @{})
            InModuleScope EES.MailboxMigration -Parameters @{ Source = $script:SourceRaw; Target = $script:TargetRaw; Extra = $Extra } {
                $params = @{
                    SourceFolder = @(ConvertTo-EESFolderTree -Folder $Source)
                    TargetFolder = @(ConvertTo-EESFolderTree -Folder $Target)
                } + $Extra
                Get-EESFolderMappingPlan @params
            }
        }
    }

    It 'associe les dossiers well-known quelle que soit la langue' {
        $plan = & $script:GetPlan
        ($plan | Where-Object SourceFolderId -EQ 'S-IN').TargetPath | Should -Be 'Inbox'
        ($plan | Where-Object SourceFolderId -EQ 'S-SENT').TargetPath | Should -Be 'Sent Items'
        ($plan | Where-Object SourceFolderId -EQ 'S-CAL').TargetAnchor | Should -Be 'calendar'
        ($plan | Where-Object SourceFolderId -EQ 'S-CAL').TargetSegments.Count | Should -Be 0
    }

    It 'recrée les sous-dossiers sous le dossier well-known cible' {
        $plan = & $script:GetPlan
        $entry = $plan | Where-Object SourceFolderId -EQ 'S-PRJ2'
        $entry.TargetAnchor | Should -Be 'inbox'
        $entry.TargetSegments | Should -Be @('Projets', '2024')
        $entry.TargetPath | Should -Be 'Inbox/Projets/2024'
    }

    It 'recrée les dossiers personnels depuis la racine' {
        $entry = & $script:GetPlan | Where-Object SourceFolderId -EQ 'S-PERSO'
        $entry.TargetAnchor | Should -BeNullOrEmpty
        $entry.TargetSegments | Should -Be @('Perso')
    }

    It 'exclut toujours les dossiers système et leurs sous-dossiers' {
        $plan = & $script:GetPlan
        ($plan | Where-Object SourceFolderId -EQ 'S-SYNC').Status | Should -Be 'Excluded'
        ($plan | Where-Object SourceFolderId -EQ 'S-CONF').Status | Should -Be 'Excluded'
    }

    It 'importe tout sous -TargetRootFolder avec les noms source' {
        $plan = & $script:GetPlan @{ TargetRootFolder = 'Migration/2025' }
        $entry = $plan | Where-Object SourceFolderId -EQ 'S-PRJ'
        $entry.TargetAnchor | Should -BeNullOrEmpty
        $entry.TargetSegments | Should -Be @('Migration', '2025', 'Boîte de réception', 'Projets')
        ($plan | Where-Object SourceFolderId -EQ 'S-CAL').TargetSegments | Should -Be @('Migration', '2025', 'Calendrier')
    }

    It 'applique -ExcludeFolders au dossier et à ses sous-dossiers' {
        $plan = & $script:GetPlan @{ ExcludeFolders = @('inbox/Projets', 'deleteditems') }
        ($plan | Where-Object SourceFolderId -EQ 'S-PRJ').Status | Should -Be 'Excluded'
        ($plan | Where-Object SourceFolderId -EQ 'S-PRJ2').Status | Should -Be 'Excluded'
        ($plan | Where-Object SourceFolderId -EQ 'S-DEL').Status | Should -Be 'Excluded'
        ($plan | Where-Object SourceFolderId -EQ 'S-IN').Status | Should -Be 'Migrate'
    }

    It 'applique -IncludeFolders (et donne la priorité à -ExcludeFolders)' {
        $plan = & $script:GetPlan @{ IncludeFolders = @('inbox'); ExcludeFolders = @('*/2024') }
        @($plan | Where-Object Status -EQ 'Migrate').SourceFolderId | Should -Be @('S-IN', 'S-PRJ')
    }

    It 'trie les entrées par profondeur (parents avant enfants)' {
        $plan = @(& $script:GetPlan)
        $depths = $plan | ForEach-Object { ($_.SourcePath -split '/').Count }
        $depths | Should -Be ($depths | Sort-Object)
    }
}

Describe 'ConvertTo-EESTargetFolderIndex' {
    It 'indexe les dossiers well-known et les enfants par nom (casse ignorée)' {
        InModuleScope EES.MailboxMigration -Parameters @{ Target = $script:TargetRaw } {
            $index = ConvertTo-EESTargetFolderIndex -Folder @(ConvertTo-EESFolderTree -Folder $Target)
            $index.WellKnown['inbox'] | Should -Be 'T-IN'
            $index.Children['ROOT|perso'] | Should -Be 'T-PERSO'
            $index.Ids.Contains('T-CAL') | Should -BeTrue
        }
    }
}

Describe 'Resolve-EESTargetFolder' {
    It 'réutilise un dossier existant et crée les dossiers manquants avec le bon type' {
        InModuleScope EES.MailboxMigration -Parameters @{ Target = $script:TargetRaw } {
            $index = ConvertTo-EESTargetFolderIndex -Folder @(ConvertTo-EESFolderTree -Folder $Target)
            $script:created = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-EESGraphRequest {
                $script:created.Add([pscustomobject]@{ Uri = $Uri; Name = $Body.displayName; Type = $Body.type })
                [pscustomobject]@{ id = "NEW-$($Body.displayName)" }
            }
            $mailbox = [pscustomobject]@{ MailboxId = 'MBX:t@t'; ApiVersion = 'v1.0'; Identity = 'cible@t.com' }
            $entry = [pscustomobject]@{ TargetAnchor = $null; TargetSegments = @('Migration', 'Calendrier'); Type = 'IPF.Appointment'; SourcePath = 'Calendrier' }

            $id = Resolve-EESTargetFolder -Mailbox $mailbox -PlanEntry $entry -Index $index

            $id | Should -Be 'NEW-Calendrier'
            $script:created.Count | Should -Be 2
            $script:created[0].Uri | Should -Be '/admin/exchange/mailboxes/MBX:t@t/folders'
            $script:created[0].Type | Should -Be 'IPF.Note'
            $script:created[1].Uri | Should -Be '/admin/exchange/mailboxes/MBX:t@t/folders/NEW-Migration/childFolders'
            $script:created[1].Type | Should -Be 'IPF.Appointment'

            # Deuxième appel : tout est dans l'index, aucune création.
            $script:created.Clear()
            Resolve-EESTargetFolder -Mailbox $mailbox -PlanEntry $entry -Index $index | Should -Be 'NEW-Calendrier'
            $script:created.Count | Should -Be 0
        }
    }

    It 'retourne directement le dossier well-known cible' {
        InModuleScope EES.MailboxMigration -Parameters @{ Target = $script:TargetRaw } {
            $index = ConvertTo-EESTargetFolderIndex -Folder @(ConvertTo-EESFolderTree -Folder $Target)
            Mock Invoke-EESGraphRequest { throw 'ne doit pas être appelé' }
            $entry = [pscustomobject]@{ TargetAnchor = 'calendar'; TargetSegments = @(); Type = 'IPF.Appointment'; SourcePath = 'Calendrier' }
            Resolve-EESTargetFolder -Mailbox ([pscustomobject]@{ MailboxId = 'm'; ApiVersion = 'v1.0'; Identity = 'x' }) -PlanEntry $entry -Index $index | Should -Be 'T-CAL'
        }
    }

    It 'récupère un dossier déjà existant en cas de conflit à la création' {
        InModuleScope EES.MailboxMigration -Parameters @{ Target = $script:TargetRaw } {
            $index = ConvertTo-EESTargetFolderIndex -Folder @(ConvertTo-EESFolderTree -Folder $Target)
            Mock Invoke-EESGraphRequest -ParameterFilter { $Method -eq 'POST' } {
                $exception = [System.Net.Http.HttpRequestException]::new('existe')
                $exception.Data['StatusCode'] = 409
                throw $exception
            }
            Mock Invoke-EESGraphRequest -ParameterFilter { $Method -ne 'POST' } {
                @([pscustomobject]@{ id = 'T-HIDDEN'; displayName = 'Archives 2020' })
            }
            $entry = [pscustomobject]@{ TargetAnchor = 'inbox'; TargetSegments = @('Archives 2020'); Type = 'IPF.Note'; SourcePath = 'x' }
            Resolve-EESTargetFolder -Mailbox ([pscustomobject]@{ MailboxId = 'm'; ApiVersion = 'v1.0'; Identity = 'x' }) -PlanEntry $entry -Index $index | Should -Be 'T-HIDDEN'
        }
    }
}
