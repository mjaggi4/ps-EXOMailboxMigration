BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive
}

Describe 'Get-EESItemAction' {
    BeforeAll {
        $script:Journal = [System.Collections.Generic.Dictionary[string, object]]::new()
        $script:Journal['A'] = [pscustomobject]@{ SourceChangeKey = 'ck1'; TargetItemId = 'tA'; TargetChangeKey = 'tck' }
    }

    It '<Case>' -ForEach @(
        @{ Case = 'nouvel élément -> Create'; Item = [pscustomobject]@{ id = 'B'; changeKey = 'x'; createdDateTime = '2025-05-01T00:00:00Z' }; Expected = 'Create' }
        @{ Case = 'déjà migré, même version -> Skip'; Item = [pscustomobject]@{ id = 'A'; changeKey = 'ck1' }; Expected = 'Skip' }
        @{ Case = 'déjà migré, modifié -> Update'; Item = [pscustomobject]@{ id = 'A'; changeKey = 'ck2' }; Expected = 'Update' }
        @{ Case = 'supprimé dans la source -> Removed'; Item = [pscustomobject]@{ id = 'A'; '@removed' = [pscustomobject]@{ reason = 'deleted' } }; Expected = 'Removed' }
        @{ Case = 'avant StartDate -> Filtered'; Item = [pscustomobject]@{ id = 'C'; changeKey = 'x'; createdDateTime = '2023-12-31T23:00:00Z' }; Expected = 'Filtered' }
        @{ Case = 'à EndDate (exclue) -> Filtered'; Item = [pscustomobject]@{ id = 'D'; changeKey = 'x'; createdDateTime = '2026-01-01T00:00:00Z' }; Expected = 'Filtered' }
    ) {
        InModuleScope EES.MailboxMigration -Parameters @{ Item = $Item; Expected = $Expected; Journal = $script:Journal } {
            $start = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $end = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            Get-EESItemAction -Item $Item -Journal $Journal -StartDate $start -EndDate $end | Should -Be $Expected
        }
    }

    It 'sans filtre de date, un élément ancien est copié' {
        InModuleScope EES.MailboxMigration -Parameters @{ Journal = $script:Journal } {
            Get-EESItemAction -Item ([pscustomobject]@{ id = 'Z'; changeKey = 'x'; createdDateTime = '2001-01-01T00:00:00Z' }) -Journal $Journal | Should -Be 'Create'
        }
    }
}

Describe 'Split-EESExportChunk' {
    It 'limite les lots à 20 éléments' {
        InModuleScope EES.MailboxMigration {
            $items = 1..45 | ForEach-Object { [pscustomobject]@{ SourceItemId = "$_"; Size = 1000 } }
            $chunks = @(Split-EESExportChunk -Item $items)
            $chunks.Count | Should -Be 3
            $chunks[0].Count | Should -Be 20
            $chunks[2].Count | Should -Be 5
        }
    }

    It 'limite la taille cumulée et isole les éléments volumineux' {
        InModuleScope EES.MailboxMigration {
            $items = @(
                [pscustomobject]@{ SourceItemId = 'a'; Size = 6MB }
                [pscustomobject]@{ SourceItemId = 'b'; Size = 6MB }
                [pscustomobject]@{ SourceItemId = 'big'; Size = 40MB }
                [pscustomobject]@{ SourceItemId = 'c'; Size = 1MB }
            )
            $chunks = @(Split-EESExportChunk -Item $items -MaxBytes 16MB)
            $chunks.Count | Should -Be 3
            $chunks[0].SourceItemId | Should -Be @('a', 'b')
            $chunks[1].SourceItemId | Should -Be @('big')
            $chunks[2].SourceItemId | Should -Be @('c')
        }
    }

    It 'retourne un lot d''un seul élément sous forme de tableau' {
        InModuleScope EES.MailboxMigration {
            $chunks = @(Split-EESExportChunk -Item @([pscustomobject]@{ SourceItemId = 'x'; Size = 1 }))
            $chunks.Count | Should -Be 1
            @($chunks[0]).Count | Should -Be 1
        }
    }
}

Describe 'ConvertTo-EESImportBody' {
    It 'construit un corps « create » valide' {
        InModuleScope EES.MailboxMigration {
            $json = ConvertTo-EESImportBody -FolderId 'F"1' -Data 'QUJD+/=='
            $parsed = $json | ConvertFrom-Json
            $parsed.FolderId | Should -Be 'F"1'
            $parsed.Mode | Should -Be 'create'
            $parsed.Data | Should -Be 'QUJD+/=='
            $parsed.PSObject.Properties['ItemId'] | Should -BeNullOrEmpty
        }
    }

    It 'construit un corps « update » avec ItemId et ChangeKey' {
        InModuleScope EES.MailboxMigration {
            $parsed = ConvertTo-EESImportBody -FolderId 'F' -Data 'QQ==' -TargetItemId 'T1' -TargetChangeKey 'CK' | ConvertFrom-Json
            $parsed.Mode | Should -Be 'update'
            $parsed.ItemId | Should -Be 'T1'
            $parsed.ChangeKey | Should -Be 'CK'
        }
    }

    It 'refuse un flux non base64' {
        InModuleScope EES.MailboxMigration {
            { ConvertTo-EESImportBody -FolderId 'F' -Data 'abc"}' } | Should -Throw
        }
    }
}

Describe 'Get-EESRedirectMailboxId' {
    It 'extrait la boîte indiquée par une erreur 409 d''archive' {
        InModuleScope EES.MailboxMigration {
            $message = 'Invalid import session. The target session is expected in mailbox MBX:f10964a6-4fd0-4f74-8@4d2e-9e48-109351d094ab.'
            Get-EESRedirectMailboxId -Message $message | Should -Be 'MBX:f10964a6-4fd0-4f74-8@4d2e-9e48-109351d094ab'
        }
    }

    It 'retourne $null sans identifiant' {
        InModuleScope EES.MailboxMigration {
            Get-EESRedirectMailboxId -Message 'Conflict' | Should -BeNullOrEmpty
        }
    }
}

Describe 'État de migration (reprise)' {
    It 'relit le journal en retenant la dernière ligne de chaque élément' {
        InModuleScope EES.MailboxMigration {
            $path = Get-EESStatePath -SourceIdentity 'a@source.com' -TargetIdentity 'b@cible.com'
            $state = Read-EESMigrationState -Path $path
            Add-EESItemJournal -State $state -Entry @(
                [pscustomobject]@{ SourceItemId = 'S1'; TargetItemId = 'T1'; SourceChangeKey = 'v1'; TargetChangeKey = 'tv1'; TargetMailboxId = 'M'; SourceFolderId = 'F' }
                [pscustomobject]@{ SourceItemId = 'S2'; TargetItemId = 'T2'; SourceChangeKey = 'v1'; TargetChangeKey = 'tv1'; TargetMailboxId = 'M'; SourceFolderId = 'F' }
            )
            Add-EESItemJournal -State $state -Entry @(
                [pscustomobject]@{ SourceItemId = 'S1'; TargetItemId = 'T1'; SourceChangeKey = 'v2'; TargetChangeKey = 'tv2'; TargetMailboxId = 'M'; SourceFolderId = 'F' }
            )

            $reloaded = Read-EESMigrationState -Path $path
            $reloaded.Items.Count | Should -Be 2
            $reloaded.Items['S1'].SourceChangeKey | Should -Be 'v2'
            $reloaded.Items['S1'].TargetChangeKey | Should -Be 'tv2'
        }
    }

    It 'conserve dossiers, jetons delta et échecs entre deux exécutions' {
        InModuleScope EES.MailboxMigration {
            $path = Get-EESStatePath -SourceIdentity 'c@source.com' -TargetIdentity 'd@cible.com' -Archive
            $path | Should -BeLike '*__archive'
            $state = Read-EESMigrationState -Path $path
            $state.Folders['F1'] = @{ TargetFolderId = 'TF1'; DeltaLink = 'https://graph/delta?$deltatoken=abc' }
            $state.Failures['X'] = @{ SourceFolderId = 'F1'; Size = 10; Error = 'boom'; Attempts = 1 }
            $state.Meta.HasCompletedRun = $true
            Save-EESMigrationState -State $state

            $reloaded = Read-EESMigrationState -Path $path
            $reloaded.Folders['F1'].DeltaLink | Should -Be 'https://graph/delta?$deltatoken=abc'
            $reloaded.Failures['X'].Error | Should -Be 'boom'
            $reloaded.Meta.HasCompletedRun | Should -BeTrue
        }
    }

    It 'produit un nom de dossier d''état valide' {
        InModuleScope EES.MailboxMigration {
            ConvertTo-EESSafeFileName -Name 'Jean Dupont:<x>@Contoso.com' | Should -Be 'jean_dupont__x_@contoso.com'
        }
    }
}

Describe 'Export-EESMailboxItemBatch' {
    BeforeAll {
        $script:Mailbox = [pscustomobject]@{ MailboxId = 'MBX:s@s'; ApiVersion = 'v1.0'; Identity = 'source@s.com' }
    }

    It 'regroupe jusqu''à 4 lots par $batch et retourne les flux' {
        InModuleScope EES.MailboxMigration -Parameters @{ Mailbox = $script:Mailbox } {
            $script:batchCalls = 0
            Mock Invoke-EESGraphRequest {
                $script:batchCalls++
                $responses = foreach ($request in $Body.requests) {
                    [pscustomobject]@{
                        id     = $request.id
                        status = 200
                        body   = [pscustomobject]@{ value = @($request.body.itemIds | ForEach-Object { [pscustomobject]@{ itemId = $_; changeKey = "ck-$_"; data = 'QQ==' } }) }
                    }
                }
                [pscustomobject]@{ responses = @($responses) }
            }
            $items = 1..90 | ForEach-Object { [pscustomobject]@{ SourceItemId = "i$_"; Size = 100 } }

            $result = Export-EESMailboxItemBatch -Mailbox $Mailbox -Item $items

            $result.Count | Should -Be 90
            $result['i90'].ChangeKey | Should -Be 'ck-i90'
            $script:batchCalls | Should -Be 2   # 5 lots de 20 -> 4 + 1
            Should -Invoke Invoke-EESGraphRequest -ParameterFilter { $Uri -eq '/$batch' -and $Method -eq 'POST' }
        }
    }

    It 'relance une sous-requête limitée (429) et isole l''élément fautif d''un lot en erreur' {
        InModuleScope EES.MailboxMigration -Parameters @{ Mailbox = $script:Mailbox } {
            $script:calls = 0
            Mock Start-Sleep {}
            Mock Invoke-EESGraphRequest {
                $script:calls++
                $responses = foreach ($request in $Body.requests) {
                    $ids = @($request.body.itemIds)
                    if ($script:calls -eq 1) {
                        [pscustomobject]@{ id = $request.id; status = 429; headers = [pscustomobject]@{ 'Retry-After' = '3' }; body = $null }
                    }
                    elseif ($ids.Count -gt 1) {
                        [pscustomobject]@{ id = $request.id; status = 500; body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'InternalError'; message = 'x' } } }
                    }
                    elseif ($ids[0] -eq 'bad') {
                        [pscustomobject]@{ id = $request.id; status = 500; body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'InternalError'; message = 'corrompu' } } }
                    }
                    else {
                        [pscustomobject]@{ id = $request.id; status = 200; body = [pscustomobject]@{ value = @([pscustomobject]@{ itemId = $ids[0]; changeKey = 'c'; data = 'QQ==' }) } }
                    }
                }
                [pscustomobject]@{ responses = @($responses) }
            }
            $items = @('ok1', 'bad', 'ok2') | ForEach-Object { [pscustomobject]@{ SourceItemId = $_; Size = 10 } }

            $result = Export-EESMailboxItemBatch -Mailbox $Mailbox -Item $items

            Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Milliseconds -eq 3000 }
            $result['ok1'].Error | Should -BeNullOrEmpty
            $result['ok2'].Data | Should -Be 'QQ=='
            $result['bad'].Error | Should -Match 'corrompu'
        }
    }

    It 'enregistre l''erreur propre à un élément' {
        InModuleScope EES.MailboxMigration -Parameters @{ Mailbox = $script:Mailbox } {
            Mock Invoke-EESGraphRequest {
                [pscustomobject]@{ responses = @([pscustomobject]@{ id = '1'; status = 200; body = [pscustomobject]@{ value = @(
                                    [pscustomobject]@{ itemId = 'a'; changeKey = 'c'; data = 'QQ==' }
                                    [pscustomobject]@{ itemId = 'b'; error = [pscustomobject]@{ code = 'ErrorItemTooLarge'; message = 'trop gros' } }
                                ) } }) }
            }
            $result = Export-EESMailboxItemBatch -Mailbox $Mailbox -Item @([pscustomobject]@{ SourceItemId = 'a'; Size = 1 }, [pscustomobject]@{ SourceItemId = 'b'; Size = 1 })
            $result['a'].Error | Should -BeNullOrEmpty
            $result['b'].Error | Should -Match 'ErrorItemTooLarge'
        }
    }

    It 'suit la redirection d''archive auxiliaire (ErrorArchiveFolderMovedPermanently)' {
        InModuleScope EES.MailboxMigration -Parameters @{ Mailbox = $script:Mailbox } {
            Mock Invoke-EESGraphRequest -ParameterFilter { $Uri -eq '/$batch' } {
                [pscustomobject]@{ responses = @([pscustomobject]@{ id = '1'; status = 200; body = [pscustomobject]@{ value = @(
                                    [pscustomobject]@{ itemId = 'aux'; Error = [pscustomobject]@{ code = 'ErrorArchiveFolderMovedPermanently'; message = 'https://graph.microsoft.com/beta/admin/exchange/mailboxes/MBX:aux@t/exportItems' } }
                                ) } }) }
            }
            Mock Invoke-EESGraphRequest -ParameterFilter { $Uri -like 'https://*MBX:aux@t/exportItems' } {
                [pscustomobject]@{ value = @([pscustomobject]@{ itemId = 'aux'; changeKey = 'c'; data = 'QkI=' }) }
            }
            $result = Export-EESMailboxItemBatch -Mailbox $Mailbox -Item @([pscustomobject]@{ SourceItemId = 'aux'; Size = 1 })
            $result['aux'].Data | Should -Be 'QkI='
        }
    }
}

Describe 'Invoke-EESItemTransfer' {
    It 'journalise les succès, enregistre les échecs et met à jour les statistiques' {
        InModuleScope EES.MailboxMigration {
            $path = Get-EESStatePath -SourceIdentity 'xfer@s.com' -TargetIdentity 'xfer@t.com'
            $state = Read-EESMigrationState -Path $path
            $state.Failures['ok-new'] = @{ Attempts = 1 }
            $stats = @{ F = (ConvertTo-EESFolderStat -SourcePath 'Inbox') }

            Mock Export-EESMailboxItemBatch {
                $d = [System.Collections.Generic.Dictionary[string, object]]::new()
                $d['ok-new'] = [pscustomobject]@{ Data = 'QQ=='; ChangeKey = 'sck1'; Error = $null }
                $d['ok-upd'] = [pscustomobject]@{ Data = 'QQ=='; ChangeKey = 'sck2'; Error = $null }
                $d['exp-fail'] = [pscustomobject]@{ Data = $null; ChangeKey = $null; Error = 'trop gros' }
                $d['imp-fail'] = [pscustomobject]@{ Data = 'QQ=='; ChangeKey = 'sck4'; Error = $null }
                , $d
            }
            Mock Import-EESMailboxItemBatch {
                $d = [System.Collections.Generic.Dictionary[string, object]]::new()
                $d['ok-new'] = [pscustomobject]@{ TargetItemId = 't1'; TargetChangeKey = 'tck1'; TargetMailboxId = 'M'; Error = $null }
                $d['ok-upd'] = [pscustomobject]@{ TargetItemId = 't2'; TargetChangeKey = 'tck2'; TargetMailboxId = 'M'; Error = $null }
                $d['imp-fail'] = [pscustomobject]@{ TargetItemId = $null; TargetChangeKey = $null; TargetMailboxId = 'M'; Error = 'HTTP 400' }
                , $d
            }
            $work = @(
                [pscustomobject]@{ SourceItemId = 'ok-new'; Size = 100; SourceFolderId = 'F'; SourcePath = 'Inbox'; FolderId = 'TF'; TargetItemId = $null; TargetChangeKey = $null; TargetMailboxId = $null }
                [pscustomobject]@{ SourceItemId = 'ok-upd'; Size = 50; SourceFolderId = 'F'; SourcePath = 'Inbox'; FolderId = 'TF'; TargetItemId = 't2'; TargetChangeKey = 'old'; TargetMailboxId = 'M' }
                [pscustomobject]@{ SourceItemId = 'exp-fail'; Size = 99MB; SourceFolderId = 'F'; SourcePath = 'Inbox'; FolderId = 'TF'; TargetItemId = $null; TargetChangeKey = $null; TargetMailboxId = $null }
                [pscustomobject]@{ SourceItemId = 'imp-fail'; Size = 10; SourceFolderId = 'F'; SourcePath = 'Inbox'; FolderId = 'TF'; TargetItemId = $null; TargetChangeKey = $null; TargetMailboxId = $null }
            )
            $source = [pscustomobject]@{ Identity = 'xfer@s.com' }
            $target = [pscustomobject]@{ Identity = 'xfer@t.com' }

            Invoke-EESItemTransfer -SourceMailbox $source -TargetMailbox $target -State $state -Work $work -Stats $stats -WarningAction SilentlyContinue

            $stats['F'].Copied | Should -Be 1
            $stats['F'].Updated | Should -Be 1
            $stats['F'].Failed | Should -Be 2
            $stats['F'].Bytes | Should -Be 150
            $state.Items['ok-new'].SourceChangeKey | Should -Be 'sck1'
            $state.Items['ok-upd'].TargetChangeKey | Should -Be 'tck2'
            $state.Failures.ContainsKey('ok-new') | Should -BeFalse
            $state.Failures['exp-fail'].Error | Should -Be 'trop gros'
            $state.Failures['imp-fail'].Error | Should -Be 'HTTP 400'
            (Read-EESMigrationState -Path $path).Items.Count | Should -Be 2
        }
    }
}
