#Requires -Version 7.4
<#
    Module EES.MailboxMigration
    Chargement des fonctions privées puis publiques (une fonction par fichier).
#>

# Constantes du module (aucun identifiant de tenant ou de client ici).
$script:EESConstants = [ordered]@{
    ModuleName                 = 'EES.MailboxMigration'
    AppDisplayName             = 'EES-MailboxMigration'
    AppTag                     = 'EES.MailboxMigration'
    # Identifiant (public et identique dans tous les tenants) de l'API Microsoft Graph.
    GraphResourceAppId         = '00000003-0000-0000-c000-000000000000'
    # Client public Microsoft « Microsoft Graph Command Line Tools » utilisé pour la connexion
    # interactive de l'administrateur (redirection http://localhost).
    AdminClientId              = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    GraphBaseUrl               = 'https://graph.microsoft.com'
    LoginBaseUrl               = 'https://login.microsoftonline.com'
    MinGraphAuthVersion        = [version]'2.25.0'
    CertificateValidityMonths  = 12
    CertificateRenewalDays     = 30
    PermissionWaitTimeoutSec   = 300
}

# Dossier du module (modèles, chargement dans les traitements parallèles).
$script:EESModuleRoot = $PSScriptRoot
# Rapports d'utilisation des boîtes en cache, par rôle.
$script:EESUsageReports = @{}

# Connexions actives par rôle (Source / Target) : contextes séparés, jamais globaux.
$script:EESConnections = @{}
# Clients MSAL publics (connexion administrateur) par tenant.
$script:EESAdminClients = @{}
# Fichier de log de la session courante (créé à la première écriture).
$script:EESLogFile = $null
# Sessions d'import (importUrl pré-authentifiées) par boîte cible.
$script:EESImportSessions = @{}
# Client HTTP partagé (imports concurrents).
$script:EESHttpClient = $null

foreach ($folder in @('Private', 'Public')) {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    if (Test-Path -LiteralPath $path) {
        Get-ChildItem -LiteralPath $path -Filter '*.ps1' -Recurse | Sort-Object -Property FullName | ForEach-Object {
            . $_.FullName
        }
    }
}

# Affichage par défaut des objets retournés.
$displaySets = @{
    'EES.MigrationResult' = @('SourceMailbox', 'TargetMailbox', 'IsArchive', 'Status', 'Copied', 'Updated', 'Skipped', 'Failed', 'Duration')
    'EES.FolderPlan'      = @('SourcePath', 'TargetPath', 'Items', 'Status')
    'EES.ReadinessResult' = @('SourceMailbox', 'TargetMailbox', 'Status', 'SourceSizeGB', 'SourceItemCount', 'TargetFreeGB', 'EstimatedDuration')
}
foreach ($typeName in $displaySets.Keys) {
    Update-TypeData -TypeName $typeName -DefaultDisplayPropertySet $displaySets[$typeName] -Force
}

# Vérification non bloquante au chargement : affiche des avertissements clairs.
Assert-EESPrerequisites -WarningOnly

$publicFunctions = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName }
Export-ModuleMember -Function $publicFunctions
