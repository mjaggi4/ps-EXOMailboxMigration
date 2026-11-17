@{
    # Module racine
    RootModule           = 'EES.MailboxMigration.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'bb1c9faa-a352-47ec-9386-eb032e9bc0f4'
    Author               = 'EES'
    CompanyName          = 'EES'
    Copyright            = '(c) EES. Tous droits réservés.'
    Description          = 'Migration de boîtes aux lettres Exchange Online : copie inter-tenant via les API Microsoft Graph mailbox import/export, export et import PST.'

    # PowerShell 7.4 minimum (ForEach-Object -Parallel, Invoke-RestMethod -StatusCodeVariable, etc.)
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')

    # Les dépendances (Microsoft.Graph.Authentication, ExchangeOnlineManagement...) ne sont
    # volontairement PAS déclarées dans RequiredModules : elles sont vérifiées par
    # Assert-EESPrerequisites afin d'afficher un message clair en français.

    FunctionsToExport    = @(
        'Connect-EESTenant'
        'Disconnect-EESTenant'
        'Get-EESConnectionStatus'
        'Remove-EESTenantApp'
        'Start-EESMailboxMigration'
        'Start-EESBatchMigration'
        'Test-EESMigrationReadiness'
        'New-EESBatchTemplate'
        'Get-EESMigrationStatus'
        'Export-EESMigrationReport'
        'Export-EESMailboxToPst'
        'Import-EESPstToMailbox'
        'Start-EESMigrationMenu'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('Exchange', 'ExchangeOnline', 'Migration', 'MicrosoftGraph', 'PST', 'Microsoft365', 'CrossTenant')
            ReleaseNotes = 'Voir CHANGELOG.md'
        }
    }
}
