BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive
}

Describe 'Get-EESRequiredPermission' {
    It 'source : lecture et export' {
        InModuleScope EES.MailboxMigration {
            $permissions = Get-EESRequiredPermission -Role Source
            $permissions | Should -Contain 'MailboxFolder.Read.All'
            $permissions | Should -Contain 'MailboxItem.Read.All'
            $permissions | Should -Contain 'MailboxItem.Export.All'
            $permissions | Should -Contain 'User.Read.All'
            $permissions | Should -Not -Contain 'MailboxItem.ImportExport.All'
        }
    }

    It 'cible : écriture des dossiers et import' {
        InModuleScope EES.MailboxMigration {
            $permissions = Get-EESRequiredPermission -Role Target
            $permissions | Should -Contain 'MailboxFolder.ReadWrite.All'
            $permissions | Should -Contain 'MailboxItem.ImportExport.All'
            $permissions | Should -Not -Contain 'MailboxItem.Export.All'
        }
    }

    It 'fusionne les rôles sans doublon' {
        InModuleScope EES.MailboxMigration {
            $permissions = Get-EESRequiredPermission -Role Source, Target
            ($permissions | Group-Object | Where-Object Count -GT 1) | Should -BeNullOrEmpty
            $permissions | Should -Contain 'MailboxItem.Export.All'
            $permissions | Should -Contain 'MailboxItem.ImportExport.All'
        }
    }
}

Describe 'Resolve-EESGraphAppRoleId' {
    BeforeAll {
        $script:AppRoles = @(
            [pscustomobject]@{ id = 'id-user'; value = 'User.Read.All'; allowedMemberTypes = @('Application') }
            [pscustomobject]@{ id = 'id-export'; value = 'MailboxItem.Export.All'; allowedMemberTypes = @('Application') }
            [pscustomobject]@{ id = 'id-delegated'; value = 'Mail.Read'; allowedMemberTypes = @('User') }
        )
    }

    It 'associe chaque permission à son identifiant' {
        InModuleScope EES.MailboxMigration -Parameters @{ AppRoles = $script:AppRoles } {
            $map = Resolve-EESGraphAppRoleId -AppRoles $AppRoles -PermissionName 'User.Read.All', 'MailboxItem.Export.All'
            $map['User.Read.All'] | Should -Be 'id-user'
            $map['MailboxItem.Export.All'] | Should -Be 'id-export'
        }
    }

    It 'lève une erreur claire si une permission n''existe pas' {
        InModuleScope EES.MailboxMigration -Parameters @{ AppRoles = $script:AppRoles } {
            { Resolve-EESGraphAppRoleId -AppRoles $AppRoles -PermissionName 'MailboxItem.ImportExport.All' } |
                Should -Throw -ExpectedMessage '*MailboxItem.ImportExport.All*'
        }
    }

    It 'ignore les rôles réservés aux utilisateurs (délégués)' {
        InModuleScope EES.MailboxMigration -Parameters @{ AppRoles = $script:AppRoles } {
            { Resolve-EESGraphAppRoleId -AppRoles $AppRoles -PermissionName 'Mail.Read' } | Should -Throw
        }
    }
}

Describe 'Merge-EESRequiredResourceAccess' {
    BeforeAll {
        $script:GraphId = '00000003-0000-0000-c000-000000000000'
    }

    It 'ajoute le bloc Microsoft Graph sur une application vide' {
        InModuleScope EES.MailboxMigration -Parameters @{ GraphId = $script:GraphId } {
            $result = Merge-EESRequiredResourceAccess -Existing @() -ResourceAppId $GraphId -RoleId 'r1', 'r2'
            $result.Changed | Should -BeTrue
            $result.RequiredResourceAccess.Count | Should -Be 1
            $result.RequiredResourceAccess[0].resourceAccess.id | Should -Be @('r1', 'r2')
            $result.RequiredResourceAccess[0].resourceAccess.type | Should -Be @('Role', 'Role')
        }
    }

    It 'ne signale aucun changement si tout est déjà présent' {
        InModuleScope EES.MailboxMigration -Parameters @{ GraphId = $script:GraphId } {
            $existing = @([pscustomobject]@{
                    resourceAppId  = $GraphId
                    resourceAccess = @([pscustomobject]@{ id = 'r1'; type = 'Role' }, [pscustomobject]@{ id = 'r2'; type = 'Role' })
                })
            (Merge-EESRequiredResourceAccess -Existing $existing -ResourceAppId $GraphId -RoleId 'r1', 'r2').Changed | Should -BeFalse
        }
    }

    It 'complète les permissions et conserve celles des autres API' {
        InModuleScope EES.MailboxMigration -Parameters @{ GraphId = $script:GraphId } {
            $existing = @(
                [pscustomobject]@{ resourceAppId = 'autre-api'; resourceAccess = @([pscustomobject]@{ id = 'x'; type = 'Role' }) }
                [pscustomobject]@{ resourceAppId = $GraphId; resourceAccess = @([pscustomobject]@{ id = 'r1'; type = 'Role' }) }
            )
            $result = Merge-EESRequiredResourceAccess -Existing $existing -ResourceAppId $GraphId -RoleId 'r1', 'r2'

            $result.Changed | Should -BeTrue
            ($result.RequiredResourceAccess | Where-Object { $_.resourceAppId -eq 'autre-api' }).resourceAccess.id | Should -Be 'x'
            ($result.RequiredResourceAccess | Where-Object { $_.resourceAppId -eq $GraphId }).resourceAccess.id | Should -Be @('r1', 'r2')
        }
    }

    It 'ne confond pas une permission déléguée (Scope) avec une permission applicative (Role)' {
        InModuleScope EES.MailboxMigration -Parameters @{ GraphId = $script:GraphId } {
            $existing = @([pscustomobject]@{ resourceAppId = $GraphId; resourceAccess = @([pscustomobject]@{ id = 'r1'; type = 'Scope' }) })
            $result = Merge-EESRequiredResourceAccess -Existing $existing -ResourceAppId $GraphId -RoleId 'r1'
            $result.Changed | Should -BeTrue
            $result.RequiredResourceAccess[0].resourceAccess.Count | Should -Be 2
        }
    }
}

Describe 'Invoke-EESWithReplicationRetry' {
    It 'réessaie sur 404 (réplication) puis réussit' {
        InModuleScope EES.MailboxMigration {
            $script:calls = 0
            Mock Start-Sleep {}
            $result = Invoke-EESWithReplicationRetry -Description 'test' -ScriptBlock {
                $script:calls++
                if ($script:calls -lt 3) {
                    $exception = [System.Net.Http.HttpRequestException]::new('404')
                    $exception.Data['StatusCode'] = 404
                    throw $exception
                }
                'ok'
            }
            $result | Should -Be 'ok'
            $script:calls | Should -Be 3
        }
    }

    It 'ne réessaie pas une erreur 403' {
        InModuleScope EES.MailboxMigration {
            $script:calls = 0
            Mock Start-Sleep {}
            {
                Invoke-EESWithReplicationRetry -Description 'test' -ScriptBlock {
                    $script:calls++
                    $exception = [System.Net.Http.HttpRequestException]::new('403')
                    $exception.Data['StatusCode'] = 403
                    throw $exception
                }
            } | Should -Throw
            $script:calls | Should -Be 1
        }
    }
}

Describe 'Test-EESAppPermission' {
    It 'détecte les permissions manquantes dans le jeton applicatif' {
        InModuleScope EES.MailboxMigration {
            Mock Get-EESAccessToken { 'jeton' }
            Mock ConvertFrom-EESJwt { [pscustomobject]@{ roles = @('User.Read.All', 'MailboxItem.Read.All') } }

            $result = Test-EESAppPermission -Role Source -Required 'User.Read.All', 'MailboxItem.Read.All', 'MailboxItem.Export.All'
            $result.IsComplete | Should -BeFalse
            $result.Missing | Should -Be @('MailboxItem.Export.All')
        }
    }

    It 'gère un jeton sans aucune permission' {
        InModuleScope EES.MailboxMigration {
            Mock Get-EESAccessToken { 'jeton' }
            Mock ConvertFrom-EESJwt { [pscustomobject]@{ tid = 't' } }

            $result = Test-EESAppPermission -Role Target -Required 'User.Read.All'
            $result.IsComplete | Should -BeFalse
            $result.Granted.Count | Should -Be 0
        }
    }
}
