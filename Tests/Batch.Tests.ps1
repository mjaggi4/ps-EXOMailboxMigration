BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive

    function New-TestCsv {
        param([string]$Name, [string[]]$Lines, [switch]$NoBom)
        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($path, ($Lines -join "`r`n"), [System.Text.UTF8Encoding]::new(-not $NoBom))
        return $path
    }
}

Describe 'ConvertTo-EESBoolean' {
    It '« <Value> » -> <Expected>' -ForEach @(
        @{ Value = 'true'; Expected = $true }
        @{ Value = 'VRAI'; Expected = $true }
        @{ Value = 'oui'; Expected = $true }
        @{ Value = '1'; Expected = $true }
        @{ Value = 'false'; Expected = $false }
        @{ Value = 'Non'; Expected = $false }
        @{ Value = ''; Expected = $false }
        @{ Value = ' 0 '; Expected = $false }
    ) {
        InModuleScope EES.MailboxMigration -Parameters @{ Value = $Value; Expected = $Expected } {
            ConvertTo-EESBoolean -Value $Value | Should -Be $Expected
        }
    }

    It 'retourne $null pour une valeur inconnue' {
        InModuleScope EES.MailboxMigration {
            ConvertTo-EESBoolean -Value 'peut-être' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-EESDate' {
    It 'accepte « <Value> »' -ForEach @(
        @{ Value = '2025-01-31' }
        @{ Value = '31/01/2025' }
        @{ Value = '2025/01/31' }
        @{ Value = '2025-01-31T08:30:00' }
        @{ Value = '31/01/2025 08:30' }
    ) {
        InModuleScope EES.MailboxMigration -Parameters @{ Value = $Value } {
            $date = ConvertTo-EESDate -Value $Value
            $date.Year | Should -Be 2025
            $date.Month | Should -Be 1
            $date.Day | Should -Be 31
        }
    }

    It 'refuse une date invalide (<Value>)' -ForEach @(@{ Value = '31/13/2025' }, @{ Value = 'demain' }, @{ Value = '01-31-2025' }) {
        InModuleScope EES.MailboxMigration -Parameters @{ Value = $Value } {
            ConvertTo-EESDate -Value $Value | Should -BeNullOrEmpty
        }
    }
}

Describe 'Import-EESBatchCsv' {
    It 'lit un CSV au séparateur « ; » (UTF-8 avec BOM) avec les colonnes facultatives' {
        $path = New-TestCsv 'ok-semicolon.csv' @(
            'SourceMailbox;TargetMailbox;IncludeArchive;TargetRootFolder;StartDate;EndDate;ExcludeFolders'
            'JDupont@Contoso.com;jean.dupont@fabrikam.com;oui;;2020-01-01;31/12/2024;deleteditems | junkemail'
            ''
            '# ligne de commentaire;x@y.com;;;;;'
            'mmartin@contoso.com;marie.martin@fabrikam.com;;Migration;;;'
        )
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Path = $path } { Import-EESBatchCsv -Path $Path }

        $result.IsValid | Should -BeTrue
        $result.Delimiter | Should -Be ';'
        $result.Rows.Count | Should -Be 2
        $first = $result.Rows[0]
        $first.SourceMailbox | Should -Be 'jdupont@contoso.com'
        $first.IncludeArchive | Should -BeTrue
        $first.StartDate.Year | Should -Be 2020
        $first.EndDate.Month | Should -Be 12
        $first.ExcludeFolders | Should -Be @('deleteditems', 'junkemail')
        $result.Rows[1].TargetRootFolder | Should -Be 'Migration'
        $result.Rows[1].IncludeArchive | Should -BeFalse
    }

    It 'détecte le séparateur « , » (UTF-8 sans BOM) et n''exige que les colonnes obligatoires' {
        $path = New-TestCsv 'ok-comma.csv' -NoBom @(
            'SourceMailbox,TargetMailbox'
            'a@contoso.com,b@fabrikam.com'
        )
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Path = $path } { Import-EESBatchCsv -Path $Path }
        $result.IsValid | Should -BeTrue
        $result.Delimiter | Should -Be ','
        $result.Rows[0].TargetMailbox | Should -Be 'b@fabrikam.com'
    }

    It 'signale une colonne obligatoire absente' {
        $path = New-TestCsv 'missing.csv' @('Source;Cible', 'a@b.com;c@d.com')
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Path = $path } { Import-EESBatchCsv -Path $Path }
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'SourceMailbox'
    }

    It 'signale les erreurs ligne par ligne' {
        $path = New-TestCsv 'errors.csv' @(
            'SourceMailbox;TargetMailbox;IncludeArchive;StartDate;EndDate'
            'pasuneadresse;b@fabrikam.com;;;'
            'c@contoso.com;d@fabrikam.com;peut-être;;'
            'e@contoso.com;f@fabrikam.com;;2025-02-01;2025-01-01'
            'g@contoso.com;h@fabrikam.com;;32/01/2025;'
        )
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Path = $path } { Import-EESBatchCsv -Path $Path }
        $result.IsValid | Should -BeFalse
        $text = $result.Errors -join "`n"
        $text | Should -Match 'Ligne 2 : SourceMailbox invalide'
        $text | Should -Match 'Ligne 3 : IncludeArchive invalide'
        $text | Should -Match 'Ligne 4 : StartDate doit être antérieure'
        $text | Should -Match 'Ligne 5 : StartDate invalide'
    }

    It 'refuse une boîte source en double et avertit pour une cible en double' {
        $path = New-TestCsv 'dupes.csv' @(
            'SourceMailbox;TargetMailbox'
            'a@contoso.com;x@fabrikam.com'
            'A@contoso.com;y@fabrikam.com'
            'b@contoso.com;x@fabrikam.com'
        )
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Path = $path } { Import-EESBatchCsv -Path $Path }
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'Boîte source en double « a@contoso.com » \(lignes 2, 3\)'
        ($result.Warnings -join ' ') | Should -Match 'x@fabrikam.com'
    }

    It 'signale un fichier sans ligne de migration' {
        $path = New-TestCsv 'empty.csv' @('SourceMailbox;TargetMailbox')
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Path = $path } { Import-EESBatchCsv -Path $Path }
        $result.IsValid | Should -BeFalse
    }
}

Describe 'New-EESBatchTemplate' {
    It 'crée un modèle valide, en UTF-8 avec BOM' {
        $path = Join-Path $TestDrive 'modele\lot.csv'
        $file = New-EESBatchTemplate -Path $path
        $file.FullName | Should -Be $path
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Path = $path } { Import-EESBatchCsv -Path $Path }
        $result.IsValid | Should -BeTrue
        $result.Rows.Count | Should -Be 2
    }

    It 'ne remplace pas un fichier existant sans -Force' {
        $path = Join-Path $TestDrive 'existe.csv'
        Set-Content -LiteralPath $path -Value 'x'
        { New-EESBatchTemplate -Path $path } | Should -Throw -ExpectedMessage '*-Force*'
        $null = New-EESBatchTemplate -Path $path -Force
        (Get-Content -LiteralPath $path -TotalCount 1) | Should -Match 'SourceMailbox'
    }

    It 'ne crée rien avec -WhatIf' {
        $path = Join-Path $TestDrive 'whatif.csv'
        New-EESBatchTemplate -Path $path -WhatIf
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}

Describe 'Test-EESExchangeLicense' {
    It 'détecte un plan Exchange actif' {
        InModuleScope EES.MailboxMigration {
            $details = @([pscustomobject]@{ skuPartNumber = 'SPB'; servicePlans = @(
                        [pscustomobject]@{ servicePlanName = 'EXCHANGE_S_STANDARD'; provisioningStatus = 'Success' }
                        [pscustomobject]@{ servicePlanName = 'TEAMS1'; provisioningStatus = 'Success' }
                    ) })
            $result = Test-EESExchangeLicense -LicenseDetails $details
            $result.HasExchange | Should -BeTrue
            $result.Plans | Should -Be @('EXCHANGE_S_STANDARD')
            $result.Skus | Should -Be @('SPB')
        }
    }

    It 'ignore EXCHANGE_S_FOUNDATION et les plans désactivés' {
        InModuleScope EES.MailboxMigration {
            $details = @([pscustomobject]@{ skuPartNumber = 'X'; servicePlans = @(
                        [pscustomobject]@{ servicePlanName = 'EXCHANGE_S_FOUNDATION'; provisioningStatus = 'Success' }
                        [pscustomobject]@{ servicePlanName = 'EXCHANGE_S_ENTERPRISE'; provisioningStatus = 'Disabled' }
                    ) })
            (Test-EESExchangeLicense -LicenseDetails $details).HasExchange | Should -BeFalse
            (Test-EESExchangeLicense -LicenseDetails @()).HasExchange | Should -BeFalse
        }
    }
}

Describe 'Test-EESMailboxPairReadiness' {
    BeforeAll {
        $script:Usage = @{
            Source = @{ 'a@contoso.com' = [pscustomobject]@{ 'Storage Used (Byte)' = '32212254720'; 'Item Count' = '15528'; 'Has Archive' = 'True'; 'Report Refresh Date' = '2026-11-15' } }
            Target = @{ 'b@fabrikam.com' = [pscustomobject]@{ 'Storage Used (Byte)' = '1073741824'; 'Prohibit Send/Receive Quota (Byte)' = '53687091200' } }
        }
        Mock -ModuleName EES.MailboxMigration Resolve-EESMailbox {
            [pscustomobject]@{ Identity = $Identity; UserId = "id-$Identity"; DisplayName = $Identity; MailboxId = "MBX:$Identity"; ApiVersion = 'v1.0'; IsArchive = [bool]$Archive }
        }
        Mock -ModuleName EES.MailboxMigration Invoke-EESGraphRequest -ParameterFilter { $Uri -like '*/licenseDetails' } {
            [pscustomobject]@{ skuPartNumber = 'SPB'; servicePlans = @([pscustomobject]@{ servicePlanName = 'EXCHANGE_S_STANDARD'; provisioningStatus = 'Success' }) }
        }
    }

    It 'calcule volume, espace libre et durée estimée, et signale l''archive non demandée' {
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Usage = $script:Usage } {
            Test-EESMailboxPairReadiness -SourceMailbox 'a@contoso.com' -TargetMailbox 'b@fabrikam.com' -SourceUsage $Usage.Source -TargetUsage $Usage.Target
        }
        $result.SourceSizeGB | Should -Be 30
        $result.SourceItemCount | Should -Be 15528
        $result.TargetFreeGB | Should -Be 49
        $result.EstimatedDuration.TotalHours | Should -Be 20
        $result.Ready | Should -BeTrue
        $result.Status | Should -Be 'Prêt avec avertissements'
        ($result.Checks | Where-Object Check -EQ 'Archive source').Status | Should -Be 'Avertissement'
        ($result.Checks | Where-Object Check -EQ 'Licence cible').Status | Should -Be 'OK'
    }

    It 'bloque si le quota de la cible est insuffisant' {
        $result = InModuleScope EES.MailboxMigration -Parameters @{ Usage = $script:Usage } {
            $target = @{ 'b@fabrikam.com' = [pscustomobject]@{ 'Storage Used (Byte)' = '45097156608'; 'Prohibit Send/Receive Quota (Byte)' = '53687091200' } }
            Test-EESMailboxPairReadiness -SourceMailbox 'a@contoso.com' -TargetMailbox 'b@fabrikam.com' -SourceUsage $Usage.Source -TargetUsage $target
        }
        $result.Ready | Should -BeFalse
        ($result.Checks | Where-Object Check -EQ 'Quota cible').Status | Should -Be 'Erreur'
    }

    It 'bloque si la boîte cible est introuvable ou sans licence Exchange' {
        Mock -ModuleName EES.MailboxMigration Resolve-EESMailbox -ParameterFilter { $Role -eq 'Target' } { throw 'Utilisateur introuvable dans le tenant Target' }
        $result = InModuleScope EES.MailboxMigration {
            Test-EESMailboxPairReadiness -SourceMailbox 'a@contoso.com' -TargetMailbox 'absent@fabrikam.com'
        }
        $result.Ready | Should -BeFalse
        ($result.Checks | Where-Object Check -EQ 'Boîte cible').Detail | Should -Match 'introuvable'
    }

    It 'intègre les contrôles communs (permissions)' {
        $result = InModuleScope EES.MailboxMigration {
            $common = @([pscustomobject]@{ Check = 'Application (cible)'; Status = 'Erreur'; Detail = 'Permissions manquantes' })
            Test-EESMailboxPairReadiness -SourceMailbox 'a@contoso.com' -TargetMailbox 'b@fabrikam.com' -CommonCheck $common
        }
        $result.Ready | Should -BeFalse
        $result.Checks[0].Check | Should -Be 'Application (cible)'
    }
}

Describe 'Start-EESBatchMigration' {
    BeforeEach {
        InModuleScope EES.MailboxMigration {
            foreach ($role in 'Source', 'Target') {
                $script:EESConnections[$role] = [pscustomobject]@{ Role = $role; TenantId = "t-$role"; ConfidentialClient = 'factice' }
            }
        }
    }
    AfterEach {
        InModuleScope EES.MailboxMigration { $script:EESConnections.Clear() }
    }

    It 'ne lance rien si le CSV contient des erreurs' {
        $path = New-TestCsv 'batch-bad.csv' @('SourceMailbox;TargetMailbox', 'mauvais;b@fabrikam.com')
        { Start-EESBatchMigration -CsvPath $path } | Should -Throw -ExpectedMessage '*aucune migration*'
    }

    It 'ne lance rien si une boîte est introuvable' {
        $path = New-TestCsv 'batch-missing.csv' @('SourceMailbox;TargetMailbox', 'a@contoso.com;b@fabrikam.com')
        Mock -ModuleName EES.MailboxMigration Resolve-EESMailbox -ParameterFilter { $Role -eq 'Target' } { throw 'Utilisateur introuvable dans le tenant Target : b@fabrikam.com' }
        Mock -ModuleName EES.MailboxMigration Resolve-EESMailbox -ParameterFilter { $Role -eq 'Source' } { [pscustomobject]@{ Identity = $Identity } }
        { Start-EESBatchMigration -CsvPath $path } | Should -Throw -ExpectedMessage '*Ligne 2 : Utilisateur introuvable*'
    }

    It 'liste les migrations prévues avec -WhatIf' {
        $path = New-TestCsv 'batch-ok.csv' @('SourceMailbox;TargetMailbox;IncludeArchive', 'a@contoso.com;b@fabrikam.com;true', 'c@contoso.com;d@fabrikam.com;')
        Mock -ModuleName EES.MailboxMigration Resolve-EESMailbox { [pscustomobject]@{ Identity = $Identity } }
        $plan = @(Start-EESBatchMigration -CsvPath $path -WhatIf)
        $plan.Count | Should -Be 2
        $plan[0].IncludeArchive | Should -BeTrue
        $plan[1].TargetMailbox | Should -Be 'd@fabrikam.com'
    }
}

Describe 'Test-EESMigrationReadiness' {
    It 'exige des tenants connectés' {
        InModuleScope EES.MailboxMigration { $script:EESConnections.Clear() }
        { Test-EESMigrationReadiness a@b.com c@d.com } | Should -Throw -ExpectedMessage '*Connect-EESTenant*'
    }
}
