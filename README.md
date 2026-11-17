# EES.MailboxMigration

Module PowerShell 7 de migration de boîtes aux lettres Exchange Online :

1. **Migration inter-tenant boîte → boîte** : copie du contenu d'une boîte du tenant A vers une boîte **déjà existante** du tenant B, sans modifier ni vider la source.
2. **Migration en lot** depuis un CSV, plusieurs boîtes en parallèle.
3. **Export d'une boîte vers PST** (Microsoft Purview eDiscovery ou Outlook classique).
4. **Import de PST vers une boîte** (service d'import Microsoft Purview).

📘 **Guide administrateur complet : [docs/guide-administrateur.md](docs/guide-administrateur.md)**

## Démarrage rapide

```powershell
# 1. Dans Windows PowerShell : installe PowerShell 7, les modules requis et le module
powershell.exe -ExecutionPolicy Bypass -File .\Install-EESMailboxMigration.ps1

# 2. Dans PowerShell 7 : menu interactif
Import-Module EES.MailboxMigration
Start-EESMigrationMenu
```

## Commandes

| Commande | Rôle |
|---|---|
| `Start-EESMigrationMenu` | Menu interactif en français (point d'entrée recommandé) |
| `Connect-EESTenant -Role Source\|Target` | Connexion ; création automatique de l'application Entra ID au premier lancement |
| `Get-EESConnectionStatus`, `Disconnect-EESTenant` | État et fermeture des connexions |
| `Remove-EESTenantApp` | Suppression de l'application et du certificat en fin de projet |
| `Test-EESMigrationReadiness` | Pré-vérifications (boîtes, licence, volume, quota, archive) |
| `Start-EESMailboxMigration` | Migration d'une boîte (reprise, incrémental, filtres) |
| `New-EESBatchTemplate`, `Start-EESBatchMigration` | Migration en lot depuis un CSV |
| `Get-EESMigrationStatus`, `Export-EESMigrationReport` | Suivi et rapports HTML / CSV |
| `Export-EESMailboxToPst` | Export PST |
| `Import-EESPstToMailbox` | Import PST |

Toutes les commandes ont une aide en français : `Get-Help Start-EESMailboxMigration -Full`. Les commandes qui modifient quelque chose acceptent `-WhatIf` et `-Confirm`.

## Technologies

- **Migration** : API Microsoft Graph *mailbox import/export* (v1.0) : export pleine fidélité (flux opaque, jamais analysé), import dans la boîte cible. **EWS n'est pas utilisé** (désactivé par Microsoft dans Exchange Online).
- **Authentification** : connexion administrateur au premier lancement, puis mode application avec certificat auto-signé (aucun secret). Les tenants source et cible sont connectés en même temps, dans des contextes séparés.
- **Débit** : respect des limites Microsoft (4 requêtes simultanées et 150 Mo / 5 min par boîte, `Retry-After`).
- **Reprise** : état par paire de boîtes (journal des éléments, jetons delta) ; une relance ne crée aucun doublon.

### Pourquoi pas la migration inter-tenant native (MRS) de Microsoft ?

Elle existe, mais elle :

- exige une licence add-on « Cross-Tenant User Data Migration » par utilisateur ;
- exige une cible de type **MailUser**, et non une boîte existante ;
- **vide la boîte source**.

Ce module copie vers des boîtes existantes et laisse la source intacte.

## Prérequis

- Windows, **PowerShell 7.4+** (installé par `Install-EESMailboxMigration.ps1`).
- `Microsoft.Graph.Authentication` 2.25+ et `ExchangeOnlineManagement` 3.5+ (installés par l'installeur).
- Un **Administrateur général** ou **Administrateur de rôle privilégié** de chaque tenant au premier lancement.

Licences, coûts (export eDiscovery « pay-as-you-go ») et permissions : voir le [guide](docs/guide-administrateur.md#4-licences-et-coûts).

## Fichiers créés sur le poste

| Emplacement | Contenu |
|---|---|
| `%APPDATA%\EES.MailboxMigration\tenants.json` | Configuration **sans secret** : TenantId, AppId, empreinte du certificat, rôles |
| `Cert:\CurrentUser\My` | Certificat `CN=EES-MailboxMigration-<TenantId>` (clé non exportable) |
| `%LOCALAPPDATA%\EES.MailboxMigration\` | `Logs`, `State` (reprise), `Reports`, `Tools` (AzCopy) |

Le dossier de travail peut être déplacé avec la variable d'environnement `EES_MAILBOXMIGRATION_HOME`.

## Structure du dépôt

```
EES.MailboxMigration/          Module (manifeste, Public/ une fonction par fichier, Private/, Templates/)
Install-EESMailboxMigration.ps1  Installeur (compatible Windows PowerShell 5.1)
Tests/                         Tests Pester 5
docs/                          Guide administrateur
build/                         Contrôle qualité (PSScriptAnalyzer + Pester), encodage
```

## Développement

```powershell
./build/Repair-EESFileEncoding.ps1      # UTF-8 avec BOM (requis pour Windows PowerShell 5.1)
./build/Invoke-EESQualityCheck.ps1      # PSScriptAnalyzer (zéro avertissement) + Pester 5
```

L'intégration continue GitHub Actions exécute le même contrôle à chaque push et pull request.
