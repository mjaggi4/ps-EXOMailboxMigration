BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive
}

Describe 'Merge-EESGrantScope' {
    It 'ajoute une permission manquante' {
        InModuleScope EES.MailboxMigration {
            $result = Merge-EESGrantScope -Current 'User.Read' -Required 'eDiscovery.ReadWrite.All'
            $result.Changed | Should -BeTrue
            $result.Scope | Should -Be 'User.Read eDiscovery.ReadWrite.All'
        }
    }

    It 'ne change rien si la permission est présente' {
        InModuleScope EES.MailboxMigration {
            (Merge-EESGrantScope -Current ' eDiscovery.Download.Read ' -Required 'eDiscovery.Download.Read').Changed | Should -BeFalse
        }
    }

    It 'gère une chaîne vide' {
        InModuleScope EES.MailboxMigration {
            (Merge-EESGrantScope -Current '' -Required 'A', 'B').Scope | Should -Be 'A B'
        }
    }
}

Describe 'Merge-EESRequiredResourceAccess (permissions déléguées)' {
    It 'ajoute des permissions de type Scope sans toucher aux Role' {
        InModuleScope EES.MailboxMigration {
            $existing = @([pscustomobject]@{ resourceAppId = 'graph'; resourceAccess = @([pscustomobject]@{ id = 'r1'; type = 'Role' }) })
            $result = Merge-EESRequiredResourceAccess -Existing $existing -ResourceAppId 'graph' -RoleId 's1' -Type Scope
            $result = Merge-EESRequiredResourceAccess -Existing @($result.RequiredResourceAccess) -ResourceAppId 'purview' -RoleId 'd1' -Type Scope
            $graph = $result.RequiredResourceAccess | Where-Object { $_.resourceAppId -eq 'graph' }
            $graph.resourceAccess.type | Should -Be @('Role', 'Scope')
            ($result.RequiredResourceAccess | Where-Object { $_.resourceAppId -eq 'purview' }).resourceAccess.id | Should -Be 'd1'
        }
    }
}

Describe 'Get-EESEDiscoveryErrorHint' {
    It 'explique la facturation pay-as-you-go' {
        InModuleScope EES.MailboxMigration {
            Get-EESEDiscoveryErrorHint -Message 'Pay-as-you-go billing subscription is required' | Should -Match 'pay-as-you-go'
        }
    }

    It 'explique le rôle eDiscovery Manager sur un 403' {
        InModuleScope EES.MailboxMigration {
            Get-EESEDiscoveryErrorHint -Message 'Forbidden' -StatusCode 403 | Should -Match 'eDiscovery Manager'
        }
    }

    It 'propose la méthode Outlook pour un problème de licence' {
        InModuleScope EES.MailboxMigration {
            Get-EESEDiscoveryErrorHint -Message 'The tenant does not have a valid license' | Should -Match 'Outlook'
        }
    }

    It 'ne donne pas de conseil pour une erreur inconnue' {
        InModuleScope EES.MailboxMigration {
            Get-EESEDiscoveryErrorHint -Message 'Erreur quelconque' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-EESEDiscoveryExport' {
    BeforeAll {
        $module = 'EES.MailboxMigration'
        Mock -ModuleName $module Initialize-EESEDiscoveryAccess { $Config }
        Mock -ModuleName $module Connect-EESAdminAccount { [pscustomobject]@{ TenantId = 't'; Account = 'compte'; UserPrincipalName = 'ediscovery@contoso.com'; ClientKey = 't|app' } }
        Mock -ModuleName $module Invoke-EESGraphRequest -ParameterFilter { $Uri -eq '/security/cases/ediscoveryCases' } { [pscustomobject]@{ id = 'case1' } }
        Mock -ModuleName $module Invoke-EESGraphRequest -ParameterFilter { $Uri -like '*/searches' } { [pscustomobject]@{ id = 'search1' } }
        Mock -ModuleName $module Invoke-EESGraphRequest -ParameterFilter { $Uri -like '*/additionalSources' } { [pscustomobject]@{ id = 'src1' } }
        Mock -ModuleName $module Invoke-EESGraphRequest -ParameterFilter { $Uri -like '*/estimateStatistics' } {
            [pscustomobject]@{ StatusCode = 202; Headers = @{ Location = [string[]]@('https://graph.microsoft.com/v1.0/op/estimate') }; Content = $null }
        }
        Mock -ModuleName $module Invoke-EESGraphRequest -ParameterFilter { $Uri -like '*/exportResult' } {
            [pscustomobject]@{ StatusCode = 202; Headers = @{ Location = [string[]]@('https://graph.microsoft.com/v1.0/op/export') }; Content = $null }
        }
        Mock -ModuleName $module Wait-EESEDiscoveryOperation -ParameterFilter { $OperationUri -like '*estimate' } {
            [pscustomobject]@{ status = 'succeeded'; indexedItemCount = 100; indexedItemsSize = 1MB; unindexedItemCount = 2; unindexedItemsSize = 0 }
        }
        Mock -ModuleName $module Wait-EESEDiscoveryOperation -ParameterFilter { $OperationUri -like '*export' } {
            [pscustomobject]@{ status = 'succeeded'; exportFileMetadata = @([pscustomobject]@{ fileName = 'Export PST.zip'; downloadUrl = 'https://proxy/1'; size = 10 }) }
        }
        Mock -ModuleName $module Save-EESDownload {
            # Crée une archive ZIP contenant un PST factice.
            $folder = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) 'zipsrc'
            $null = New-Item -Path $folder -ItemType Directory -Force
            Set-Content -LiteralPath (Join-Path $folder 'boite.pst') -Value 'pst'
            Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $Path -Force
            Remove-Item -LiteralPath $folder -Recurse -Force
            Get-Item -LiteralPath $Path
        }
    }

    It 'enchaîne dossier, recherche, estimation, export, téléchargement et extraction' {
        $out = Join-Path $TestDrive 'pst'
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Out = $out } {
            $config = [pscustomobject]@{ TenantId = 't'; TenantName = 'T'; AppId = 'app'; EDiscoveryConfigured = $true }
            Invoke-EESEDiscoveryExport -Config $config -Mailbox 'jdupont@contoso.com' -OutputPath $Out
        }

        $result.CaseName | Should -BeLike 'EES-Export-jdupont@contoso.com-*'
        $result.ItemCount | Should -Be 102
        @($result.Files).Name | Should -Contain 'boite.pst'
        Should -Invoke -ModuleName EES.MailboxMigration Initialize-EESEDiscoveryAccess -Times 0 -Exactly
        Should -Invoke -ModuleName EES.MailboxMigration Connect-EESAdminAccount -Times 1 -Exactly -ParameterFilter { $ClientId -eq 'app' }
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESGraphRequest -ParameterFilter {
            $Uri -like '*/additionalSources' -and $Body.email -eq 'jdupont@contoso.com' -and $Body.includedSources -eq 'mailbox'
        }
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESGraphRequest -ParameterFilter {
            $Uri -like '*/exportResult' -and $Body.exportFormat -eq 'pst'
        }
        Should -Invoke -ModuleName EES.MailboxMigration Save-EESDownload -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://proxy/1' -and $ExpectedSize -eq 10 }
    }

    It 'prépare l''application au premier usage' {
        $out = Join-Path $TestDrive 'pst2'
        $null = InModuleScope EES.MailboxMigration -Parameters @{ Out = $out } {
            $config = [pscustomobject]@{ TenantId = 't'; TenantName = 'T'; AppId = 'app' }
            Invoke-EESEDiscoveryExport -Config $config -Mailbox 'jdupont@contoso.com' -OutputPath $Out -NoExtract
        }
        Should -Invoke -ModuleName EES.MailboxMigration Initialize-EESEDiscoveryAccess -Times 1 -Exactly
    }
}

Describe 'Export-EESMailboxToPst' {
    BeforeEach {
        InModuleScope EES.MailboxMigration { $script:EESConnections.Clear() }
    }

    It 'exige un tenant configuré pour la méthode EDiscovery' {
        { Export-EESMailboxToPst -Mailbox a@contoso.com -OutputPath $TestDrive -Role Target } | Should -Throw -ExpectedMessage '*Connect-EESTenant -Role Target*'
    }

    It 'ne fait rien avec -WhatIf' {
        Mock -ModuleName EES.MailboxMigration Invoke-EESOutlookPstExport { throw 'ne doit pas être appelé' }
        Export-EESMailboxToPst -Mailbox a@contoso.com -OutputPath $TestDrive -Method Outlook -WhatIf | Should -BeNullOrEmpty
    }

    It 'retourne un résultat en échec avec un conseil, sans lever d''erreur' {
        InModuleScope EES.MailboxMigration {
            Save-EESTenantConfig -InputObject ([pscustomobject]@{ TenantId = 'ts'; TenantName = 'Source'; Roles = @('Source'); AppId = 'app' })
        }
        Mock -ModuleName EES.MailboxMigration Invoke-EESEDiscoveryExport {
            $exception = [System.Net.Http.HttpRequestException]::new('Forbidden')
            $exception.Data['StatusCode'] = 403
            throw $exception
        }
        $result = Export-EESMailboxToPst -Mailbox a@contoso.com -OutputPath $TestDrive -Confirm:$false -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'eDiscovery Manager'
    }

    It 'retourne les fichiers produits par la méthode Outlook' {
        $pst = Join-Path $TestDrive 'outlook.pst'
        Set-Content -LiteralPath $pst -Value 'pst'
        Mock -ModuleName EES.MailboxMigration Invoke-EESOutlookPstExport { Get-Item -LiteralPath $pst }
        $result = Export-EESMailboxToPst -Mailbox a@contoso.com -OutputPath $TestDrive -Method Outlook -Confirm:$false
        $result.Status | Should -Be 'Completed'
        $result.Files | Should -Be @($pst)
    }
}
