BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive

    function ConvertTo-TestBase64Url {
        param([string]$Text)
        [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
}

Describe 'ConvertFrom-EESJwt' {
    It 'décode les claims roles et tid (longueur de payload <Pad>)' -ForEach @(
        @{ Pad = '' }
        @{ Pad = 'x' }
        @{ Pad = 'xy' }
    ) {
        $payload = '{"tid":"t-1","roles":["MailboxItem.Read.All","User.Read.All"],"p":"' + $Pad + '"}'
        $token = '{0}.{1}.signature' -f (ConvertTo-TestBase64Url '{"alg":"RS256"}'), (ConvertTo-TestBase64Url $payload)

        InModuleScope EES.MailboxMigration -Parameters @{ Token = $token } {
            $claims = ConvertFrom-EESJwt -Token $Token
            $claims.tid | Should -Be 't-1'
            $claims.roles | Should -Be @('MailboxItem.Read.All', 'User.Read.All')
        }
    }

    It 'gère les caractères base64url (- et _)' {
        $payload = '{"name":"é?>>~~"}'
        $token = 'h.{0}.s' -f (ConvertTo-TestBase64Url $payload)
        InModuleScope EES.MailboxMigration -Parameters @{ Token = $token } {
            (ConvertFrom-EESJwt -Token $Token).name | Should -Be 'é?>>~~'
        }
    }

    It 'rejette un jeton invalide' {
        InModuleScope EES.MailboxMigration {
            { ConvertFrom-EESJwt -Token 'pasunjeton' } | Should -Throw
        }
    }
}

Describe 'Get-EESAccessToken' {
    It 'indique clairement qu''il faut se connecter si le rôle n''est pas connecté' {
        InModuleScope EES.MailboxMigration {
            $script:EESConnections.Clear()
            { Get-EESAccessToken -Role Source } | Should -Throw -ExpectedMessage '*Connect-EESTenant -Role Source*'
        }
    }

    It 'exige une connexion administrateur pour un jeton délégué' {
        InModuleScope EES.MailboxMigration {
            $script:EESConnections['Target'] = [pscustomobject]@{ Role = 'Target'; TenantId = 't'; AdminAccount = $null; ConfidentialClient = $null }
            { Get-EESAccessToken -Role Target -Delegated } | Should -Throw -ExpectedMessage '*-Repair*'
            $script:EESConnections.Clear()
        }
    }
}

Describe 'Get-EESConnectionStatus' {
    It 'retourne un état « Non configuré » pour chaque rôle sans connexion ni configuration' {
        InModuleScope EES.MailboxMigration {
            $script:EESConnections.Clear()
            $status = @(Get-EESConnectionStatus)
            $status.Count | Should -Be 2
            $status.Connected | Should -Be @($false, $false)
            $status[0].Status | Should -Be 'Non configuré'
        }
    }
}
