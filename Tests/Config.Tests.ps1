BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive
}

Describe 'Configuration des tenants (tenants.json)' {
    BeforeEach {
        $configFile = Join-Path -Path $env:EES_MAILBOXMIGRATION_CONFIG -ChildPath 'tenants.json'
        if (Test-Path -LiteralPath $configFile) {
            Remove-Item -LiteralPath $configFile -Force
        }
    }

    It 'ne retourne rien si aucun fichier n''existe' {
        InModuleScope EES.MailboxMigration {
            @(Get-EESTenantConfig).Count | Should -Be 0
        }
    }

    It 'enregistre puis relit un tenant par GUID, domaine et rôle' {
        InModuleScope EES.MailboxMigration {
            Save-EESTenantConfig -InputObject ([pscustomobject]@{
                    TenantId              = '11111111-1111-1111-1111-111111111111'
                    TenantName            = 'Tenant A'
                    DefaultDomain         = 'a.onmicrosoft.com'
                    Roles                 = @('Source')
                    AppId                 = 'app-a'
                    CertificateThumbprint = 'ABC'
                })

            (Get-EESTenantConfig -TenantId '11111111-1111-1111-1111-111111111111').AppId | Should -Be 'app-a'
            (Get-EESTenantConfig -TenantId 'a.onmicrosoft.com').AppId | Should -Be 'app-a'
            (Get-EESTenantConfig -Role Source).AppId | Should -Be 'app-a'
            @(Get-EESTenantConfig -Role Target).Count | Should -Be 0
        }
    }

    It 'met à jour un tenant existant sans le dupliquer' {
        InModuleScope EES.MailboxMigration {
            $base = @{ TenantId = '22222222-2222-2222-2222-222222222222'; TenantName = 'B'; DefaultDomain = 'b.com'; Roles = @('Target') }
            Save-EESTenantConfig -InputObject ([pscustomobject]($base + @{ AppId = 'v1' }))
            Save-EESTenantConfig -InputObject ([pscustomobject]($base + @{ AppId = 'v2' }))

            $all = @(Get-EESTenantConfig)
            $all.Count | Should -Be 1
            $all[0].AppId | Should -Be 'v2'
            $all[0].UpdatedAt | Should -Not -BeNullOrEmpty
        }
    }

    It 'conserve un tableau de rôles même avec un seul rôle' {
        InModuleScope EES.MailboxMigration {
            Save-EESTenantConfig -InputObject ([pscustomobject]@{ TenantId = 't1'; TenantName = 'T'; Roles = [string[]]@('Source') })
            $raw = Get-Content -LiteralPath (Join-Path (Get-EESPath -Kind Config) 'tenants.json') -Raw
            $raw | Should -Match '"Roles":\s*\[\s*"Source"\s*\]'
        }
    }

    It 'ne stocke aucun secret' {
        InModuleScope EES.MailboxMigration {
            Save-EESTenantConfig -InputObject ([pscustomobject]@{ TenantId = 't2'; TenantName = 'T2'; Roles = @('Source'); CertificateThumbprint = 'ABCDEF' })
            $raw = Get-Content -LiteralPath (Join-Path (Get-EESPath -Kind Config) 'tenants.json') -Raw
            $raw | Should -Not -Match '(?i)secret|password|privatekey'
        }
    }

    It 'supprime un tenant et conserve les autres' {
        InModuleScope EES.MailboxMigration {
            Save-EESTenantConfig -InputObject ([pscustomobject]@{ TenantId = 'x'; TenantName = 'X'; Roles = @('Source') })
            Save-EESTenantConfig -InputObject ([pscustomobject]@{ TenantId = 'y'; TenantName = 'Y'; Roles = @('Target') })

            Remove-EESTenantConfig -TenantId 'x' -Confirm:$false

            (@(Get-EESTenantConfig)).TenantId | Should -Be @('y')
        }
    }

    It 'respecte -WhatIf lors de la suppression' {
        InModuleScope EES.MailboxMigration {
            Save-EESTenantConfig -InputObject ([pscustomobject]@{ TenantId = 'z'; TenantName = 'Z'; Roles = @('Source') })
            Remove-EESTenantConfig -TenantId 'z' -WhatIf
            @(Get-EESTenantConfig -TenantId 'z').Count | Should -Be 1
        }
    }
}

Describe 'Get-EESPath' {
    It 'crée les dossiers de travail sous la racine configurée' {
        InModuleScope EES.MailboxMigration {
            foreach ($kind in 'Logs', 'State', 'Reports') {
                $path = Get-EESPath -Kind $kind
                $path | Should -BeLike "$($env:EES_MAILBOXMIGRATION_HOME)*"
                Test-Path -LiteralPath $path | Should -BeTrue
            }
        }
    }
}
