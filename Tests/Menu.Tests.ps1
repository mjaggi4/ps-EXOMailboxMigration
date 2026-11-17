BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive
}

Describe 'Start-EESMigrationMenu' {
    It 'quitte sur « 0 »' {
        Mock -ModuleName EES.MailboxMigration Read-EESInput { '0' }
        Mock -ModuleName EES.MailboxMigration Invoke-EESMenuAction { throw 'ne doit pas être appelé' }
        { Start-EESMigrationMenu } | Should -Not -Throw
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESMenuAction -Times 0 -Exactly
    }

    It 'exécute l''action choisie, affiche les erreurs sans quitter, puis quitte' {
        $script:answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('99', '3', '', '5', '', '0'))
        Mock -ModuleName EES.MailboxMigration Read-EESInput { $script:answers.Dequeue() }
        Mock -ModuleName EES.MailboxMigration Invoke-EESMenuAction -ParameterFilter { $Choice -eq '5' } { throw 'boîte introuvable' }
        Mock -ModuleName EES.MailboxMigration Invoke-EESMenuAction -ParameterFilter { $Choice -eq '3' } { }

        { Start-EESMigrationMenu } | Should -Not -Throw

        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESMenuAction -Times 1 -Exactly -ParameterFilter { $Choice -eq '3' }
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESMenuAction -Times 1 -Exactly -ParameterFilter { $Choice -eq '5' }
        Should -Invoke -ModuleName EES.MailboxMigration Invoke-EESMenuAction -Times 0 -Exactly -ParameterFilter { $Choice -eq '99' }
        $script:answers.Count | Should -Be 0
    }
}

Describe 'Invoke-EESMenuAction' {
    It 'migration d''une boîte : affiche le plan puis lance la copie après confirmation' {
        $script:answers = [System.Collections.Generic.Queue[object]]::new([object[]]@('a@contoso.com', 'b@fabrikam.com', $false, '', $true, $true))
        Mock -ModuleName EES.MailboxMigration Read-EESInput { $script:answers.Dequeue() }
        Mock -ModuleName EES.MailboxMigration Start-EESMailboxMigration { }

        InModuleScope EES.MailboxMigration { Invoke-EESMenuAction -Choice '5' }

        # Un appel pour le plan (-WhatIf), un pour la copie.
        Should -Invoke -ModuleName EES.MailboxMigration Start-EESMailboxMigration -Times 2 -Exactly -ParameterFilter {
            $SourceMailbox -eq 'a@contoso.com' -and $TargetMailbox -eq 'b@fabrikam.com'
        }
        $script:answers.Count | Should -Be 0
    }

    It 'passe incrémentale : lance directement avec -Incremental' {
        $script:answers = [System.Collections.Generic.Queue[object]]::new([object[]]@('a@contoso.com', 'b@fabrikam.com'))
        Mock -ModuleName EES.MailboxMigration Read-EESInput { $script:answers.Dequeue() }
        Mock -ModuleName EES.MailboxMigration Start-EESMailboxMigration { }

        InModuleScope EES.MailboxMigration { Invoke-EESMenuAction -Choice '7' }

        Should -Invoke -ModuleName EES.MailboxMigration Start-EESMailboxMigration -Times 1 -Exactly -ParameterFilter { $Incremental }
    }

    It 'lot sans fichier : crée un modèle CSV' {
        $path = Join-Path $TestDrive 'menu-lot.csv'
        $script:answers = [System.Collections.Generic.Queue[object]]::new([object[]]@('', $path))
        Mock -ModuleName EES.MailboxMigration Read-EESInput { $script:answers.Dequeue() }

        InModuleScope EES.MailboxMigration { Invoke-EESMenuAction -Choice '6' }

        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'signale un choix inconnu' {
        { InModuleScope EES.MailboxMigration { Invoke-EESMenuAction -Choice '42' } } | Should -Not -Throw
    }
}

Describe 'Install-EESMailboxMigration.ps1' {
    It 'se charge sans erreur de syntaxe sous Windows PowerShell 5.1' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $installer = (Resolve-Path (Join-Path $PSScriptRoot '..\Install-EESMailboxMigration.ps1')).Path
        $check = "`$errors = `$null; `$null = [System.Management.Automation.Language.Parser]::ParseFile('$installer', [ref]`$null, [ref]`$errors); `$errors.Count"
        $result = & powershell.exe -NoProfile -NonInteractive -Command $check
        [int]($result | Select-Object -Last 1) | Should -Be 0
    }

    It 'a une aide complète' {
        $help = Get-Help (Join-Path $PSScriptRoot '..\Install-EESMailboxMigration.ps1') -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }
}
