# Guide administrateur – EES.MailboxMigration

Ce guide s'adresse à l'administrateur Microsoft 365 qui réalise la migration. Aucune compétence de développement n'est nécessaire : le menu `Start-EESMigrationMenu` guide chaque étape.

## Sommaire

1. [Ce que fait le module](#1-ce-que-fait-le-module)
2. [Prérequis](#2-prérequis)
3. [Installation](#3-installation)
4. [Licences et coûts](#4-licences-et-coûts)
5. [Connexion aux tenants et permissions](#5-connexion-aux-tenants-et-permissions)
6. [Migrer une boîte](#6-migrer-une-boîte)
7. [Migrer un lot de boîtes](#7-migrer-un-lot-de-boîtes)
8. [Bascule MX et passe finale](#8-bascule-mx-et-passe-finale)
9. [Suivi et rapports](#9-suivi-et-rapports)
10. [Export PST](#10-export-pst)
11. [Import PST](#11-import-pst)
12. [Limites connues](#12-limites-connues)
13. [Dépannage](#13-dépannage)
14. [Fin de projet](#14-fin-de-projet)

---

## 1. Ce que fait le module

| Besoin | Commande | Technologie |
|---|---|---|
| Copier une boîte du tenant A vers une boîte existante du tenant B | `Start-EESMailboxMigration` | API Microsoft Graph *mailbox import/export* |
| Copier plusieurs boîtes en parallèle | `Start-EESBatchMigration` | Idem, 4 boîtes à la fois par défaut |
| Exporter une boîte en PST | `Export-EESMailboxToPst` | Microsoft Purview eDiscovery (ou Outlook classique) |
| Importer un PST dans une boîte | `Import-EESPstToMailbox` | Service d'import Microsoft Purview (AzCopy) |

La boîte source **n'est jamais modifiée** et rien n'est supprimé dans la boîte cible. EWS n'est pas utilisé (Microsoft le désactive dans Exchange Online).

**Pourquoi pas la migration inter-tenant native de Microsoft ?** Elle exige une licence add-on « Cross-Tenant User Data Migration » par utilisateur, une cible de type *MailUser* (pas une boîte existante) et elle vide la boîte source.

## 2. Prérequis

| Élément | Détail |
|---|---|
| Poste | Windows 10/11 ou Windows Server, accès Internet |
| PowerShell | **PowerShell 7.4 ou supérieur** (installé automatiquement par l'installeur) |
| Modules | Microsoft.Graph.Authentication 2.25+, ExchangeOnlineManagement 3.5+ (installés par l'installeur) |
| Compte de configuration | **Administrateur général** ou **Administrateur de rôle privilégié** de chaque tenant, au premier lancement |
| Boîtes cibles | Créées à l'avance ; sous licence Exchange Online (sauf boîtes partagées ≤ 50 Go) |
| Archives | Archive activée dans la cible si vous copiez les archives |

Le poste doit rester allumé pendant les migrations (désactivez la mise en veille).

## 3. Installation

1. Téléchargez et décompressez le dépôt, par exemple dans `C:\EES.MailboxMigration`.
2. Ouvrez **Windows PowerShell** et lancez :

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File C:\EES.MailboxMigration\Install-EESMailboxMigration.ps1
   ```

   L'installeur :
   - installe PowerShell 7 avec `winget` s'il est absent, puis se relance dedans ;
   - propose la stratégie d'exécution `RemoteSigned` pour votre compte ;
   - débloque les fichiers téléchargés ;
   - installe les modules nécessaires pour votre compte uniquement ;
   - copie le module dans votre dossier de modules PowerShell 7.

3. Ouvrez **PowerShell 7** (`pwsh`) et lancez le menu :

   ```powershell
   Import-Module EES.MailboxMigration
   Start-EESMigrationMenu
   ```

Options de l'installeur : `-InstallAzCopy` (télécharge AzCopy tout de suite), `-IncludeAzureModules` (Az.Accounts, Az.Storage), `-Force` (aucune question).

## 4. Licences et coûts

| Fonction | Licence | Coût supplémentaire |
|---|---|---|
| Migration boîte → boîte | Aucune licence spécifique (boîtes Exchange Online) | Aucun |
| Export PST (eDiscovery) | eDiscovery (Standard) : Microsoft 365 E3, Business Premium… | Pour E3 / Business : **abonnement Azure « pay-as-you-go » Purview obligatoire** ; l'export est facturé au volume au-delà d'un quota mensuel gratuit |
| Export PST (Outlook) | Outlook classique installé | Aucun |
| Import PST (NetworkUpload) | Inclus dans Exchange Online | Aucun (stockage Microsoft fourni) |

Avec **Business Standard**, l'export eDiscovery n'est généralement pas disponible : utilisez `-Method Outlook`.

## 5. Connexion aux tenants et permissions

```powershell
Connect-EESTenant -Role Source
Connect-EESTenant -Role Target -TenantId fabrikam.onmicrosoft.com
Get-EESConnectionStatus
```

**Au premier lancement**, une fenêtre de connexion s'ouvre : connectez-vous avec un administrateur du tenant. Le module crée alors l'application Entra ID **EES-MailboxMigration** :

- inscription d'application et service principal ;
- permissions applicatives Microsoft Graph et **consentement administrateur** accordé automatiquement ;
- **certificat auto-signé** (aucun secret) dans `Cert:\CurrentUser\My`, valable 12 mois.

**Aux lancements suivants**, la connexion se fait sans interaction grâce au certificat.

Administrateur partenaire (GDAP) : précisez toujours `-TenantId` (domaine du client).

| Tenant | Permissions applicatives (Microsoft Graph) |
|---|---|
| Source | `User.Read.All`, `Organization.Read.All`, `Reports.Read.All`, `MailboxFolder.Read.All`, `MailboxItem.Read.All`, `MailboxItem.Export.All` |
| Cible | `User.Read.All`, `Organization.Read.All`, `Reports.Read.All`, `MailboxFolder.ReadWrite.All`, `MailboxItem.Read.All`, `MailboxItem.ImportExport.All` |

Pour l'export PST, des permissions **déléguées** sont ajoutées au premier usage : `eDiscovery.ReadWrite.All` (Graph) et `eDiscovery.Download.Read` (MicrosoftPurviewEDiscovery).

Si une permission manque (par exemple après une mise à jour du module), `Connect-EESTenant` le détecte et redemande la connexion administrateur. Pour forcer une vérification complète : `Connect-EESTenant -Role Source -Repair`.

## 6. Migrer une boîte

1. **Pré-vérifications** :

   ```powershell
   Test-EESMigrationReadiness jdupont@contoso.com jean.dupont@fabrikam.com
   ```

   La ligne `Issues` liste les erreurs (bloquantes) et avertissements. `Checks` détaille tous les contrôles : boîtes, licence, volume, quota, archive.

2. **Plan des dossiers** (rien n'est copié) :

   ```powershell
   Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com -WhatIf
   ```

3. **Copie** :

   ```powershell
   Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com
   ```

### Dossiers

- Les dossiers standard (Boîte de réception, Éléments envoyés, Calendrier, Contacts…) sont associés à leurs équivalents dans la cible **quelle que soit la langue** des deux boîtes.
- Les dossiers personnels sont recréés avec le même chemin.
- `-TargetRootFolder 'Migration'` importe tout sous un dossier « Migration ».
- Les dossiers système (dossiers de recherche, problèmes de synchronisation, boîte d'envoi) ne sont jamais copiés.

### Filtres

```powershell
Start-EESMailboxMigration jdupont@contoso.com jean.dupont@fabrikam.com `
    -StartDate 2022-01-01 -ExcludeFolders 'deleteditems','junkemail'
```

- `-IncludeFolders` / `-ExcludeFolders` : nom affiché (`'Boîte de réception/Projets'`) ou nom indépendant de la langue (`'inbox/Projets'`), jokers acceptés. Un dossier inclut ses sous-dossiers.
- `-StartDate` / `-EndDate` : date de création de l'élément (en pratique, date de réception d'un message).

### Archive (expérimental)

`-IncludeArchive` copie l'archive source dans l'archive cible (qui doit être activée). Microsoft ne publie l'identifiant d'archive que dans l'API Graph beta : la fonction est signalée comme expérimentale.

### Reprise et durée

- **Relancer la même commande reprend** là où elle s'est arrêtée (coupure, veille, Ctrl+C), sans doublon.
- Les éléments en échec sont journalisés et **retentés automatiquement** à la relance suivante.
- `-BadItemLimit 50` arrête la migration au-delà de 50 éléments en échec (par défaut : illimité).
- **Débit** : Microsoft limite les envois à environ 150 Mo par tranche de 5 minutes et par boîte cible. Comptez environ **1,2 Go/h par boîte**. Les longues pauses visibles avec `-Verbose` sont normales.

## 7. Migrer un lot de boîtes

1. Créez le modèle et complétez-le dans Excel :

   ```powershell
   New-EESBatchTemplate -Path C:\Migration\lot1.csv
   ```

   | Colonne | Obligatoire | Exemple |
   |---|---|---|
   | SourceMailbox | oui | jdupont@contoso.com |
   | TargetMailbox | oui | jean.dupont@fabrikam.com |
   | IncludeArchive | non | true / false (ou oui / non) |
   | TargetRootFolder | non | Migration |
   | StartDate, EndDate | non | 2022-01-01 ou 01/01/2022 |
   | IncludeFolders, ExcludeFolders | non | deleteditems\|junkemail |

   Séparateur `;` ou `,`, encodage UTF-8. Les lignes commençant par `#` sont ignorées.

2. Vérifiez puis lancez :

   ```powershell
   Test-EESMigrationReadiness -CsvPath C:\Migration\lot1.csv
   Start-EESBatchMigration -CsvPath C:\Migration\lot1.csv -ThrottleLimit 4
   ```

Le fichier est entièrement validé **avant** tout lancement : adresses, dates, doublons, boîtes existantes. Comme chaque boîte a sa propre limite de débit, migrer plusieurs boîtes en parallèle augmente le débit global.

## 8. Bascule MX et passe finale

1. Migrez toutes les boîtes (plusieurs jours avant la bascule si le volume est important).
2. Juste avant de basculer les enregistrements MX, lancez une **passe incrémentale** : elle ne copie que les nouveautés et les modifications.

   ```powershell
   Start-EESBatchMigration -CsvPath C:\Migration\lot1.csv -Incremental
   ```

3. Basculez les MX, puis relancez une dernière passe incrémentale pour les messages arrivés pendant la propagation DNS.

### Réponses aux invitations de réunion

Les réunions copiées gardent l'adresse interne (LegacyExchangeDN) de l'organisateur source. Pour que les réponses arrivent, ajoutez cette adresse en alias X500 sur la boîte cible :

```powershell
# Tenant source (Exchange Online PowerShell)
(Get-EXOMailbox jdupont@contoso.com -Properties LegacyExchangeDN).LegacyExchangeDN
# Tenant cible
Set-Mailbox jean.dupont@fabrikam.com -EmailAddresses @{ Add = 'X500:<valeur obtenue>' }
```

## 9. Suivi et rapports

```powershell
Get-EESMigrationStatus                     # état de toutes les migrations
Get-EESMigrationStatus -SourceMailbox jdupont@* | Format-List
Export-EESMigrationReport -Open            # rapport HTML + CSV
```

`Get-EESMigrationStatus` fonctionne **dans une autre fenêtre pendant une migration** : le nombre d'éléments migrés augmente au fil de l'eau.

Le rapport HTML présente une synthèse, puis pour chaque boîte le détail par dossier (éléments source, copiés, déjà présents, filtrés, en échec) et la liste des éléments en échec. Les CSV (`;`, UTF-8) s'ouvrent directement dans Excel.

## 10. Export PST

```powershell
Export-EESMailboxToPst jdupont@contoso.com D:\PST
Export-EESMailboxToPst jdupont@contoso.com D:\PST -Method Outlook
```

**Méthode eDiscovery** (par défaut) :

- au premier usage sur un tenant, une connexion administrateur prépare l'application ;
- le compte qui lance l'export doit avoir le rôle Purview **eDiscovery Manager** (portail Purview > Paramètres > Rôles et étendues > Groupes de rôles), qui peut mettre jusqu'à une heure à s'appliquer ;
- pour les licences E3 / Business, Microsoft exige l'abonnement **pay-as-you-go** (voir § 4) ;
- étapes automatiques : dossier eDiscovery `EES-Export-…`, recherche sur la boîte, estimation, export PST, téléchargement (reprise automatique en cas de coupure), extraction ;
- le dossier eDiscovery est conservé pour la traçabilité ; supprimez-le dans le portail Purview si besoin.

**Méthode Outlook** : Outlook classique (le nouvel Outlook n'est pas compatible), avec la boîte ouverte dans votre profil Outlook (accès total). Plus lente, sans coût.

## 11. Import PST

```powershell
Import-EESPstToMailbox -PstPath D:\PST\jdupont.pst -TargetMailbox jean.dupont@fabrikam.com
```

1. Dans le portail Purview : **Gestion du cycle de vie des données > Microsoft 365 > Importer > Nouveau travail d'importation > Charger vos données**, puis copiez l'**URL SAS** (« Afficher l'URL SAS de chargement réseau »). Elle donne accès en écriture au stockage : ne la communiquez pas.
2. Lancez la commande et collez l'URL quand elle est demandée (saisie masquée, jamais enregistrée dans les logs).
3. Le module télécharge AzCopy si besoin, téléverse les PST et génère le **fichier de mappage**.
4. Terminez dans le portail Purview en suivant les étapes affichées : sélection du fichier de mappage, validation, analyse, puis import.

Options : `-TargetRootFolder 'Import PST'` (sinon fusion dans les dossiers existants), `-IsArchive` (archive, 100 Go maximum par import), `-MappingOnly` (régénère seulement le mappage).

Prérequis : rôle **Mailbox Import Export** pour le compte qui crée le travail. PST de 20 Go maximum conseillés, noms uniques.

La méthode `-Method AzurePstImport` (nouvelle fonctionnalité Purview annoncée, déploiement prévu fin mars – fin avril 2027) n'est pas encore documentée par Microsoft : le module l'indique et vous oriente vers `NetworkUpload`.

## 12. Limites connues

| Sujet | Détail |
|---|---|
| Éléments non migrés | Règles de boîte, délégations et permissions de dossiers, réponse automatique, liste des catégories, éléments récupérables |
| Taille d'élément | Limite Exchange Online (150 Mo) ; les éléments plus gros sont signalés en échec |
| Éléments déplacés | Un élément déplacé dans la source après la première passe est recopié dans son nouveau dossier ; l'ancienne copie reste |
| Conflits | Un élément modifié à la fois dans la source et dans la cible est signalé en échec plutôt que dupliqué |
| Archive | Expérimental (API Graph beta pour l'identifiant d'archive) |
| Rapports de volume | Données Microsoft 365 avec 24 à 48 h de décalage ; non disponibles si les noms sont masqués dans les rapports (Paramètres de l'organisation > Rapports) |

## 13. Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `Connect-EESTenant` : droits insuffisants | Compte non Administrateur général / Administrateur de rôle privilégié | Utiliser un compte adapté |
| Statut « Bloquant » | Voir la propriété `Issues` | Corriger le point signalé |
| Nombreuses pauses pendant la copie | Limite Microsoft 150 Mo / 5 min par boîte | Normal ; migrer plusieurs boîtes en parallèle |
| `ApplicationThrottled` dans les logs | Limitation Microsoft | Géré automatiquement (pause puis reprise) |
| Export eDiscovery : 403 | Rôle eDiscovery Manager absent | Ajouter le rôle et attendre jusqu'à une heure |
| Export eDiscovery : facturation | Abonnement pay-as-you-go absent | Le configurer dans Purview, ou `-Method Outlook` |
| Certificat expiré | Validité 12 mois | `Connect-EESTenant -Role Source -RenewCertificate` |

**Logs** : `%LOCALAPPDATA%\EES.MailboxMigration\Logs`, un fichier horodaté par exécution. `-Verbose` affiche le détail à l'écran.

## 14. Fin de projet

```powershell
Remove-EESTenantApp -Role Source
Remove-EESTenantApp -Role Target
```

Supprime l'application Entra ID (et ses permissions), la purge de la corbeille, le certificat local et la configuration. Les données migrées ne sont pas touchées.

Fichiers locaux à supprimer à la main si besoin : `%APPDATA%\EES.MailboxMigration` (configuration) et `%LOCALAPPDATA%\EES.MailboxMigration` (logs, état des migrations, rapports, AzCopy).
