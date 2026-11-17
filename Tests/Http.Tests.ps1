BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive
}

Describe 'Get-EESRetryDelay' {
    It 'respecte un Retry-After en secondes' {
        InModuleScope EES.MailboxMigration {
            Get-EESRetryDelay -Attempt 1 -RetryAfter '7' | Should -Be 7
        }
    }

    It 'impose au moins 1 seconde (Retry-After: 0)' {
        InModuleScope EES.MailboxMigration {
            Get-EESRetryDelay -Attempt 1 -RetryAfter '0' | Should -Be 1
        }
    }

    It 'plafonne un Retry-After excessif' {
        InModuleScope EES.MailboxMigration {
            Get-EESRetryDelay -Attempt 1 -RetryAfter '86400' -MaxRetryAfterSeconds 900 | Should -Be 900
        }
    }

    It 'respecte un Retry-After au format date HTTP' {
        InModuleScope EES.MailboxMigration {
            $now = [datetime]::new(2026, 11, 17, 10, 0, 0, [System.DateTimeKind]::Utc)
            Get-EESRetryDelay -Attempt 1 -RetryAfter 'Tue, 17 Nov 2026 10:00:30 GMT' -Now $now | Should -Be 30
        }
    }

    It 'applique un backoff exponentiel sans Retry-After (tentative <Attempt> -> <Expected> s)' -ForEach @(
        @{ Attempt = 1; Expected = 2 }
        @{ Attempt = 2; Expected = 4 }
        @{ Attempt = 3; Expected = 8 }
        @{ Attempt = 10; Expected = 120 }
    ) {
        InModuleScope EES.MailboxMigration -Parameters @{ Attempt = $Attempt; Expected = $Expected } {
            Get-EESRetryDelay -Attempt $Attempt -NoJitter | Should -Be $Expected
        }
    }

    It 'ajoute une gigue comprise entre 0 et 1 seconde' {
        InModuleScope EES.MailboxMigration {
            1..20 | ForEach-Object {
                $delay = Get-EESRetryDelay -Attempt 2 -RetryAfter ''
                $delay | Should -BeGreaterOrEqual 4
                $delay | Should -BeLessThan 5
            }
        }
    }
}

Describe 'Test-EESRetryableStatusCode' {
    It '<Code> est réessayable : <Expected>' -ForEach @(
        @{ Code = 429; Expected = $true }
        @{ Code = 503; Expected = $true }
        @{ Code = 504; Expected = $true }
        @{ Code = 502; Expected = $true }
        @{ Code = 400; Expected = $false }
        @{ Code = 401; Expected = $false }
        @{ Code = 404; Expected = $false }
        @{ Code = 500; Expected = $false }
    ) {
        InModuleScope EES.MailboxMigration -Parameters @{ Code = $Code; Expected = $Expected } {
            Test-EESRetryableStatusCode -StatusCode $Code | Should -Be $Expected
        }
    }
}

Describe 'Get-EESHeaderValue' {
    It 'trouve un en-tête sans tenir compte de la casse et retourne la première valeur' {
        InModuleScope EES.MailboxMigration {
            $headers = @{ 'retry-after' = [string[]]@('12', '99') }
            Get-EESHeaderValue -Headers $headers -Name 'Retry-After' | Should -Be '12'
        }
    }

    It 'retourne $null si l''en-tête est absent' {
        InModuleScope EES.MailboxMigration {
            Get-EESHeaderValue -Headers @{} -Name 'Retry-After' | Should -BeNullOrEmpty
            Get-EESHeaderValue -Headers $null -Name 'Retry-After' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-EESSafeUri' {
    It 'masque la chaîne de requête (jetons d''import ou SAS)' {
        InModuleScope EES.MailboxMigration {
            $safe = ConvertTo-EESSafeUri -Uri 'https://outlook.office365.com/api/gv1.0/Mailboxes(''MBX:1@2'')/importItem?authtoken=SECRET'
            $safe | Should -Not -Match 'SECRET'
            $safe | Should -BeLike 'https://outlook.office365.com/api/gv1.0/Mailboxes*importItem?*'
        }
    }

    It 'laisse une URL sans paramètre inchangée' {
        InModuleScope EES.MailboxMigration {
            ConvertTo-EESSafeUri -Uri 'https://graph.microsoft.com/v1.0/users' | Should -Be 'https://graph.microsoft.com/v1.0/users'
        }
    }
}

Describe 'ConvertTo-EESHttpException' {
    It 'extrait le code et le message d''une erreur Graph' {
        InModuleScope EES.MailboxMigration {
            $content = [pscustomobject]@{ error = [pscustomobject]@{ code = 'ErrorItemNotFound'; message = 'Introuvable' } }
            $exception = ConvertTo-EESHttpException -Method GET -Uri 'https://graph.microsoft.com/v1.0/x?y=1' -StatusCode 404 -Content $content
            $exception.Data['StatusCode'] | Should -Be 404
            $exception.Data['ErrorCode'] | Should -Be 'ErrorItemNotFound'
            $exception.Message | Should -Match 'HTTP 404'
            $exception.Message | Should -Match 'Introuvable'
            $exception.Message | Should -Not -Match 'y=1'
        }
    }

    It 'gère le format { Message } du point de terminaison d''import' {
        InModuleScope EES.MailboxMigration {
            $content = [pscustomobject]@{ Message = 'Invalid import session.' }
            $exception = ConvertTo-EESHttpException -Method POST -Uri 'https://outlook.office365.com/x' -StatusCode 409 -Content $content
            $exception.Data['ErrorMessage'] | Should -Be 'Invalid import session.'
        }
    }
}

Describe 'Invoke-EESRestRequest' {
    It 'réessaie sur 429 en respectant Retry-After puis retourne le contenu' {
        InModuleScope EES.MailboxMigration {
            $script:calls = 0
            Mock Start-Sleep {}
            Mock Send-EESHttpRequest {
                $script:calls++
                if ($script:calls -lt 3) {
                    [pscustomobject]@{ StatusCode = 429; Headers = @{ 'Retry-After' = [string[]]@('7') }; Content = $null }
                }
                else {
                    [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = [pscustomobject]@{ ok = $true } }
                }
            }

            $result = Invoke-EESRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/test'

            $result.ok | Should -BeTrue
            Should -Invoke Send-EESHttpRequest -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Milliseconds -eq 7000 }
        }
    }

    It 'réessaie sur 503 et 504 sans Retry-After' {
        InModuleScope EES.MailboxMigration {
            $script:responses = [System.Collections.Generic.Queue[int]]::new([int[]]@(503, 504, 200))
            Mock Start-Sleep {}
            Mock Send-EESHttpRequest {
                [pscustomobject]@{ StatusCode = $script:responses.Dequeue(); Headers = @{}; Content = 'ok' }
            }

            Invoke-EESRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/test' | Should -Be 'ok'
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }
    }

    It 'lève une exception explicite après épuisement des tentatives' {
        InModuleScope EES.MailboxMigration {
            Mock Start-Sleep {}
            Mock Send-EESHttpRequest { [pscustomobject]@{ StatusCode = 503; Headers = @{}; Content = $null } }

            { Invoke-EESRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/test' -MaxRetries 2 } |
                Should -Throw -ExpectedMessage '*HTTP 503*'
            Should -Invoke Send-EESHttpRequest -Times 3 -Exactly
        }
    }

    It 'ne réessaie pas une erreur définitive (404) et expose le code HTTP' {
        InModuleScope EES.MailboxMigration {
            Mock Start-Sleep {}
            Mock Send-EESHttpRequest {
                [pscustomobject]@{ StatusCode = 404; Headers = @{}; Content = [pscustomobject]@{ error = [pscustomobject]@{ code = 'NotFound'; message = 'absent' } } }
            }

            $caught = $null
            try {
                Invoke-EESRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/test'
            }
            catch {
                $caught = $_.Exception
            }
            $caught.Data['StatusCode'] | Should -Be 404
            $caught.Data['ErrorCode'] | Should -Be 'NotFound'
            Should -Invoke Send-EESHttpRequest -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'réessaie les erreurs réseau' {
        InModuleScope EES.MailboxMigration {
            $script:calls = 0
            Mock Start-Sleep {}
            Mock Send-EESHttpRequest {
                $script:calls++
                if ($script:calls -eq 1) {
                    throw [System.Net.Http.HttpRequestException]::new('connexion interrompue')
                }
                [pscustomobject]@{ StatusCode = 201; Headers = @{}; Content = 'créé' }
            }

            Invoke-EESRestRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/test' -Body '{}' | Should -Be 'créé'
            Should -Invoke Send-EESHttpRequest -Times 2 -Exactly
        }
    }

    It 'retourne la réponse complète avec -PassThru' {
        InModuleScope EES.MailboxMigration {
            Mock Send-EESHttpRequest { [pscustomobject]@{ StatusCode = 202; Headers = @{ Location = [string[]]@('https://x/op/1') }; Content = $null } }

            $response = Invoke-EESRestRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/test' -Body '{}' -PassThru
            $response.StatusCode | Should -Be 202
            Get-EESHeaderValue -Headers $response.Headers -Name 'location' | Should -Be 'https://x/op/1'
        }
    }

    It 'n''écrit jamais le jeton d''une URL pré-authentifiée dans le log' {
        InModuleScope EES.MailboxMigration {
            $script:calls = 0
            Mock Start-Sleep {}
            Mock Send-EESHttpRequest {
                $script:calls++
                if ($script:calls -eq 1) {
                    [pscustomobject]@{ StatusCode = 429; Headers = @{}; Content = $null }
                }
                else {
                    [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = 'ok' }
                }
            }

            $null = Invoke-EESRestRequest -Method POST -Uri 'https://outlook.office365.com/api/gv1.0/importItem?authtoken=TOPSECRET' -Body '{}' -WarningAction SilentlyContinue
            Get-Content -LiteralPath $script:EESLogFile -Raw | Should -Not -Match 'TOPSECRET'
        }
    }
}

Describe 'Invoke-EESGraphRequest' {
    It 'construit l''URL Graph à partir d''un chemin relatif' {
        InModuleScope EES.MailboxMigration {
            Mock Get-EESAccessToken { 'jeton' }
            Mock Invoke-EESRestRequest { [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = 'ok' } }

            Invoke-EESGraphRequest -Role Source -Uri '/users/a@b.com/settings/exchange' | Should -Be 'ok'
            Should -Invoke Invoke-EESRestRequest -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/v1.0/users/a@b.com/settings/exchange' -and $Headers.Authorization -eq 'Bearer jeton'
            }
        }
    }

    It 'utilise la version beta si demandée' {
        InModuleScope EES.MailboxMigration {
            Mock Get-EESAccessToken { 'jeton' }
            Mock Invoke-EESRestRequest { [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = 'ok' } }

            $null = Invoke-EESGraphRequest -Role Target -Uri 'users' -ApiVersion beta
            Should -Invoke Invoke-EESRestRequest -ParameterFilter { $Uri -eq 'https://graph.microsoft.com/beta/users' }
        }
    }

    It 'suit @odata.nextLink avec -All' {
        InModuleScope EES.MailboxMigration {
            Mock Get-EESAccessToken { 'jeton' }
            Mock Invoke-EESRestRequest {
                if ($Uri -like '*skip=2*') {
                    [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = [pscustomobject]@{ value = @(3) } }
                }
                else {
                    [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = [pscustomobject]@{ value = @(1, 2); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/items?$skip=2' } }
                }
            }

            $items = @(Invoke-EESGraphRequest -Role Source -Uri '/items' -All)
            $items | Should -Be @(1, 2, 3)
            Should -Invoke Invoke-EESRestRequest -Times 2 -Exactly
        }
    }

    It 'rafraîchit le jeton une seule fois sur 401' {
        InModuleScope EES.MailboxMigration {
            $script:calls = 0
            Mock Get-EESAccessToken { if ($ForceRefresh) { 'neuf' } else { 'ancien' } }
            Mock Invoke-EESRestRequest {
                $script:calls++
                if ($Headers.Authorization -eq 'Bearer ancien') {
                    $exception = [System.Net.Http.HttpRequestException]::new('401')
                    $exception.Data['StatusCode'] = 401
                    throw $exception
                }
                [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = 'ok' }
            }

            Invoke-EESGraphRequest -Role Source -Uri '/me' | Should -Be 'ok'
            $script:calls | Should -Be 2
            Should -Invoke Get-EESAccessToken -Times 1 -Exactly -ParameterFilter { $ForceRefresh }
        }
    }

    It 'sérialise le corps en JSON' {
        InModuleScope EES.MailboxMigration {
            Mock Get-EESAccessToken { 'jeton' }
            Mock Invoke-EESRestRequest { [pscustomobject]@{ StatusCode = 201; Headers = @{}; Content = 'ok' } }

            $null = Invoke-EESGraphRequest -Role Target -Method POST -Uri '/x' -Body @{ itemIds = @('a') }
            Should -Invoke Invoke-EESRestRequest -ParameterFilter { $Body -eq '{"itemIds":["a"]}' }
        }
    }
}
