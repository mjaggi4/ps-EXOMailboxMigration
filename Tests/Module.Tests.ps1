BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1') -TestRoot $TestDrive
    $script:ModuleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\EES.MailboxMigration'
}

Describe 'Manifeste et chargement du module' {
    It 'le manifeste est valide et exige PowerShell 7.4' {
        $manifest = Test-ModuleManifest -Path (Join-Path $script:ModuleRoot 'EES.MailboxMigration.psd1') -WarningAction SilentlyContinue
        $manifest.PowerShellVersion | Should -Be ([version]'7.4')
    }

    It 'exporte exactement les fonctions du dossier Public et celles déclarées dans le manifeste' {
        $publicFiles = Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -Recurse | ForEach-Object BaseName | Sort-Object
        $manifestData = Import-PowerShellDataFile -Path (Join-Path $script:ModuleRoot 'EES.MailboxMigration.psd1')
        $exported = (Get-Command -Module EES.MailboxMigration).Name | Sort-Object

        $exported | Should -Be $publicFiles
        ($manifestData.FunctionsToExport | Sort-Object) | Should -Be $publicFiles
    }

    It 'chaque fichier contient une fonction du même nom' {
        Get-ChildItem -Path $script:ModuleRoot -Filter '*.ps1' -Recurse | ForEach-Object {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
            $functions.Name | Should -Contain $_.BaseName -Because $_.FullName
        }
    }
}

Describe 'Aide des commandes publiques' {
    BeforeDiscovery {
        $script:Commands = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\EES.MailboxMigration\Public') -Filter '*.ps1' -Recurse |
            ForEach-Object { @{ Name = $_.BaseName } }
    }

    It '<Name> a un synopsis, une description et au moins un exemple' -ForEach $script:Commands {
        $help = Get-Help -Name $Name -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Description | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }

    It '<Name> documente tous ses paramètres' -ForEach $script:Commands {
        $command = Get-Command -Name $Name
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $help = Get-Help -Name $Name -Full
        foreach ($parameter in $command.Parameters.Keys | Where-Object { $_ -notin $common }) {
            $parameterHelp = $help.Parameters.Parameter | Where-Object Name -EQ $parameter
            $parameterHelp.Description | Should -Not -BeNullOrEmpty -Because "le paramètre -$parameter de $Name doit être documenté"
        }
    }
}

Describe 'Prise en charge de -WhatIf' {
    It '<_> supporte -WhatIf et -Confirm' -ForEach @('Connect-EESTenant', 'Disconnect-EESTenant', 'Remove-EESTenantApp', 'Start-EESMailboxMigration', 'Start-EESBatchMigration', 'New-EESBatchTemplate', 'Export-EESMigrationReport') {
        $command = Get-Command -Name $_
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
    }
}
