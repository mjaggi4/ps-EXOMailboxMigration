BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive
    $script:Sas = 'https://abc123.blob.core.windows.net/ingestiondata?sv=2012-02-12&se=9999-12-31T23%3A59%3A59Z&sr=c&si=IngestionSasForAzCopy&sig=SECRET%3D'
}

Describe 'Get-EESSasUploadUri' {
    It 'insère le sous-dossier après ingestiondata et conserve la signature' {
        InModuleScope EES.MailboxMigration -Parameters @{ Sas = $script:Sas } {
            $uri = Get-EESSasUploadUri -SasUrl $Sas -Folder 'EES-20261117'
            $uri | Should -BeLike 'https://abc123.blob.core.windows.net/ingestiondata/EES-20261117?sv=*'
            $uri | Should -Match 'sig=SECRET'
        }
    }

    It 'refuse <Case>' -ForEach @(
        @{ Case = 'un autre hôte'; Url = 'https://evil.example.com/ingestiondata?sig=x' }
        @{ Case = 'une URL sans signature'; Url = 'https://abc.blob.core.windows.net/ingestiondata?sv=1' }
        @{ Case = 'un autre conteneur'; Url = 'https://abc.blob.core.windows.net/autre?sig=x' }
        @{ Case = 'http'; Url = 'http://abc.blob.core.windows.net/ingestiondata?sig=x' }
    ) {
        InModuleScope EES.MailboxMigration -Parameters @{ Url = $Url } {
            { Get-EESSasUploadUri -SasUrl $Url -Folder 'X' } | Should -Throw
        }
    }
}

Describe 'ConvertTo-EESPurviewRootFolder' {
    It '« <Value> » -> « <Expected> »' -ForEach @(
        @{ Value = ''; Expected = '/' }
        @{ Value = '/'; Expected = '/' }
        @{ Value = 'Import PST'; Expected = '/Import PST' }
        @{ Value = '\Archives\2020\'; Expected = '/Archives/2020' }
    ) {
        InModuleScope EES.MailboxMigration -Parameters @{ Value = $Value; Expected = $Expected } {
            ConvertTo-EESPurviewRootFolder -TargetRootFolder $Value | Should -Be $Expected
        }
    }
}

Describe 'ConvertTo-EESPstMappingCsv' {
    It 'produit l''en-tête exact de Purview et une ligne par PST' {
        InModuleScope EES.MailboxMigration {
            $files = @(ConvertTo-EESPstMappingCsv -Entry @(
                    [pscustomobject]@{ FilePath = 'EES-1'; Name = 'annb.pst'; Mailbox = 'annb@contoso.com'; IsArchive = $false; TargetRootFolder = '/' }
                    [pscustomobject]@{ FilePath = 'EES-1'; Name = 'annb_archive.pst'; Mailbox = 'annb@contoso.com'; IsArchive = $true; TargetRootFolder = '/ImportedPst' }
                ))
            $files.Count | Should -Be 1
            $files[0][0] | Should -BeExactly 'Workload,FilePath,Name,Mailbox,IsArchive,TargetRootFolder,ContentCodePage,SPFileContainer,SPManifestContainer,SPSiteUrl'
            $files[0][1] | Should -BeExactly 'Exchange,EES-1,annb.pst,annb@contoso.com,FALSE,/,,,,'
            $files[0][2] | Should -BeExactly 'Exchange,EES-1,annb_archive.pst,annb@contoso.com,TRUE,/ImportedPst,,,,'
        }
    }

    It 'découpe au-delà de 500 lignes' {
        InModuleScope EES.MailboxMigration {
            $entries = 1..1001 | ForEach-Object { [pscustomobject]@{ FilePath = 'F'; Name = "$_.pst"; Mailbox = 'a@b.com'; IsArchive = $false; TargetRootFolder = '/' } }
            $files = @(ConvertTo-EESPstMappingCsv -Entry $entries)
            $files.Count | Should -Be 3
            $files[0].Count | Should -Be 501
            $files[2].Count | Should -Be 2
        }
    }

    It 'protège les valeurs contenant une virgule' {
        InModuleScope EES.MailboxMigration {
            $files = @(ConvertTo-EESPstMappingCsv -Entry @([pscustomobject]@{ FilePath = 'F'; Name = 'a.pst'; Mailbox = 'a@b.com'; IsArchive = $false; TargetRootFolder = '/Dupont, Jean' }))
            $files[0][1] | Should -Match '"/Dupont, Jean"'
        }
    }
}

Describe 'Test-EESAzurePstImport' {
    It 'indique clairement que la fonctionnalité n''est pas disponible' {
        $result = InModuleScope EES.MailboxMigration { Test-EESAzurePstImport }
        $result.Available | Should -BeFalse
        $result.Message | Should -Match 'NetworkUpload'
    }
}

Describe 'Import-EESPstToMailbox' {
    BeforeAll {
        $script:PstDir = Join-Path $TestDrive 'pst'
        $null = New-Item -Path $script:PstDir -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $script:PstDir 'jdupont.pst') -Value 'pst'
        Set-Content -LiteralPath (Join-Path $script:PstDir 'jdupont_2.pst') -Value 'pst'
    }

    It 'retourne NotAvailable pour AzurePstImport sans rien modifier' {
        $result = Import-EESPstToMailbox -PstPath $script:PstDir -TargetMailbox a@fabrikam.com -Method AzurePstImport -WarningAction SilentlyContinue
        $result.Status | Should -Be 'NotAvailable'
    }

    It 'téléverse avec AzCopy et génère le mappage' {
        $fakeAzCopy = Join-Path $TestDrive 'azcopy.ps1'
        Set-Content -LiteralPath $fakeAzCopy -Value '$global:AzCopyArgs = $args; $global:LASTEXITCODE = 0'
        Mock -ModuleName EES.MailboxMigration Get-EESAzCopy { $fakeAzCopy }
        $mappingDir = Join-Path $TestDrive 'mapping'

        $result = Import-EESPstToMailbox -PstPath $script:PstDir -TargetMailbox jean.dupont@fabrikam.com -SasUrl $script:Sas `
            -UploadFolder 'EES-TEST' -MappingPath $mappingDir -TargetRootFolder 'Import PST' -Confirm:$false

        $result.Status | Should -Be 'Uploaded'
        $global:AzCopyArgs[0] | Should -Be 'copy'
        $global:AzCopyArgs[2] | Should -BeLike 'https://abc123.blob.core.windows.net/ingestiondata/EES-TEST?*'
        ($global:AzCopyArgs[4] -split ';' | Sort-Object) | Should -Be (@('jdupont.pst', 'jdupont_2.pst') | Sort-Object)
        $lines = Get-Content -LiteralPath $result.MappingFiles[0]
        $lines.Count | Should -Be 3
        $lines | Should -Contain 'Exchange,EES-TEST,jdupont.pst,jean.dupont@fabrikam.com,FALSE,/Import PST,,,,'
        Get-Content -LiteralPath (Get-ChildItem (Join-Path $env:EES_MAILBOXMIGRATION_HOME 'Logs') -Filter *.log | Select-Object -First 1).FullName -Raw |
            Should -Not -Match 'SECRET'
    }

    It 'génère seulement le mappage avec -MappingOnly' {
        Mock -ModuleName EES.MailboxMigration Get-EESAzCopy { throw 'ne doit pas être appelé' }
        $result = Import-EESPstToMailbox -PstPath (Join-Path $script:PstDir 'jdupont.pst') -TargetMailbox a@fabrikam.com -MappingOnly -IsArchive -MappingPath (Join-Path $TestDrive 'm2') -Confirm:$false
        $result.Status | Should -Be 'MappingGenerated'
        (Get-Content -LiteralPath $result.MappingFiles[0])[1] | Should -Match ',TRUE,/,'
    }

    It 'refuse des noms de PST en double' {
        $other = Join-Path $TestDrive 'autre'
        $null = New-Item -Path $other -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $other 'JDupont.pst') -Value 'pst'
        { Import-EESPstToMailbox -PstPath $script:PstDir, $other -TargetMailbox a@fabrikam.com -MappingOnly -Confirm:$false } | Should -Throw -ExpectedMessage '*uniques*'
    }

    It 'ne téléverse rien avec -WhatIf' {
        Mock -ModuleName EES.MailboxMigration Get-EESAzCopy { throw 'ne doit pas être appelé' }
        Import-EESPstToMailbox -PstPath $script:PstDir -TargetMailbox a@fabrikam.com -WhatIf | Should -BeNullOrEmpty
    }
}
