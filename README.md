# EES.MailboxMigration

Module PowerShell pour migrer des boîtes aux lettres Exchange Online :

1. **Migration inter-tenant boîte → boîte** : le contenu d'une boîte du tenant A (source) est copié vers une boîte **déjà existante** du tenant B (cible), sans modifier ni supprimer la source.
2. **Migration en lot** depuis un fichier CSV.
3. **Export d'une boîte vers un fichier PST.**
4. **Import d'un fichier PST vers une boîte.**

> 🚧 Développement en cours : connexion aux tenants et migration unitaire disponibles. Voir [CHANGELOG.md](CHANGELOG.md).

## Technologies utilisées

- **Moteur de migration** : API Microsoft Graph *mailbox import/export* (v1.0). Les éléments sont copiés en pleine fidélité (flux opaque, jamais analysé). **EWS n'est pas utilisé** : Microsoft le désactive dans Exchange Online.
- **Authentification** : connexion interactive de l'administrateur au premier lancement, puis mode application (certificat auto-signé, aucun secret). Les deux tenants peuvent être connectés en même temps.

### Pourquoi pas la migration inter-tenant native de Microsoft ?

Microsoft propose aussi une migration inter-tenant native (*cross-tenant mailbox migration*, basée sur MRS). Ce module ne l'utilise pas, car elle :

- exige une licence add-on « Cross-Tenant User Data Migration » par utilisateur ;
- exige une cible de type **MailUser**, et non une boîte existante ;
- déplace la boîte : la source est vidée.

## Prérequis

- Windows et **PowerShell 7.4 ou supérieur**.
- Module `Microsoft.Graph.Authentication` 2.25 ou supérieur.
- Pour la création de l'application : un compte **Administrateur général** ou **Administrateur de rôle privilégié** de chaque tenant.

## Démarrage rapide (étape 1)

```powershell
Import-Module .\EES.MailboxMigration\EES.MailboxMigration.psd1

# Tenant source : au premier lancement, connexion administrateur puis création de l'application
Connect-EESTenant -Role Source

# Tenant cible (préciser le domaine si vous êtes administrateur partenaire/GDAP)
Connect-EESTenant -Role Target -TenantId fabrikam.onmicrosoft.com

Get-EESConnectionStatus

# Plan de correspondance des dossiers, sans rien copier
Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com -WhatIf

# Copie (relançable sans doublon), puis passe finale avant la bascule MX
Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com
Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com -Incremental

# En fin de projet
Remove-EESTenantApp -Role Source
Remove-EESTenantApp -Role Target
```

## Permissions applicatives créées

| Tenant | Permissions Microsoft Graph (application) |
|---|---|
| Source | `User.Read.All`, `Organization.Read.All`, `MailboxFolder.Read.All`, `MailboxItem.Read.All`, `MailboxItem.Export.All` |
| Cible | `User.Read.All`, `Organization.Read.All`, `MailboxFolder.ReadWrite.All`, `MailboxItem.Read.All`, `MailboxItem.ImportExport.All` |

## Fichiers créés sur le poste

| Emplacement | Contenu |
|---|---|
| `%APPDATA%\EES.MailboxMigration\tenants.json` | Configuration **sans secret** : TenantId, AppId, empreinte du certificat, rôles |
| `Cert:\CurrentUser\My` | Certificat `CN=EES-MailboxMigration-<TenantId>` (clé non exportable) |
| `%LOCALAPPDATA%\EES.MailboxMigration\Logs` | Logs horodatés de chaque exécution |

Le dossier de travail peut être déplacé avec la variable d'environnement `EES_MAILBOXMIGRATION_HOME`.

## Développement

```powershell
./build/Repair-EESFileEncoding.ps1      # UTF-8 avec BOM (nécessaire pour PowerShell 5.1)
./build/Invoke-EESQualityCheck.ps1      # PSScriptAnalyzer + Pester 5
```
