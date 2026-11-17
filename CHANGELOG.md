# Journal des modifications

Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/). Versionnage sémantique.

## [Non publié]

### Ajouté – étape 3 : lot, parallélisme et pré-vérifications

- `Start-EESBatchMigration` : migration en parallèle (`ForEach-Object -Parallel`, `-ThrottleLimit` 4 par défaut) depuis un CSV ; reconnexion non interactive par certificat dans chaque runspace ; log commun ; récapitulatif `Reports/Lot_*.json`.
- Validation du CSV avant lancement : séparateur `;` ou `,` détecté, UTF-8 avec ou sans BOM, colonnes, adresses, booléens (true/oui/1…), dates (2025-01-31 ou 31/01/2025), doublons de source (erreur) et de cible (avertissement), existence des boîtes.
- `New-EESBatchTemplate` : modèle CSV (UTF-8 avec BOM, séparateur `;`).
- `Test-EESMigrationReadiness` : permissions, boîtes, licence Exchange de la cible, volume, nombre d'éléments, quota libre, archives, détail par dossier (`-Detailed`), durée estimée.
- Nouvelle permission applicative `Reports.Read.All` (rapport d'utilisation des boîtes) : consentement redemandé au prochain `Connect-EESTenant`.

### Modifié

- Lecture de l'arborescence des dossiers en temps linéaire (boîtes de plusieurs milliers de dossiers).
- L'état de reprise est distinct pour chaque `-TargetRootFolder`.

### Ajouté – étape 2 : migration unitaire

- `Start-EESMailboxMigration` : copie inter-tenant boîte → boîte existante via les API Microsoft Graph mailbox import/export (flux FastTransfer opaque, jamais analysé).
- Correspondance des dossiers well-known indépendante de la langue (`wellKnownName`), recréation des dossiers personnels par chemin, option `-TargetRootFolder`.
- Filtres `-StartDate`, `-EndDate` (sur `createdDateTime`), `-IncludeFolders`, `-ExcludeFolders` (noms affichés ou canoniques, jokers). Dossiers système toujours exclus.
- Reprise et incrémental : état par paire de boîtes (`State/`), journal des éléments en ajout seul, jetons delta par dossier, `-Incremental`, `-Rescan`. Relance automatique des éléments en échec.
- Export en `$batch` (4 × 20 éléments, taille de lot limitée), import concurrent (4 requêtes simultanées par boîte), renouvellement de la session d'import, gestion des redirections d'archive auxiliaire (308/`ErrorArchiveFolderMovedPermanently`/409).
- `-BadItemLimit`, barre de progression, résultat détaillé par dossier (`last-run.json`, `runs.jsonl`).
- `-IncludeArchive` (expérimental) : identifiant d'archive lu via `settings/exchange` en beta, opérations en v1.0 avec repli beta.
- `-WhatIf` affiche le plan de correspondance des dossiers.

### Ajouté – étape 1 : authentification et application d'entreprise

- Squelette du module `EES.MailboxMigration` (PowerShell 7.4 minimum, une fonction par fichier).
- `Connect-EESTenant` :
  - connexion interactive de l'administrateur (MSAL, navigateur système) ;
  - création ou réutilisation idempotente de l'application Entra ID `EES-MailboxMigration` (inscription, service principal, permissions applicatives Microsoft Graph, consentement administrateur par programme) ;
  - certificat auto-signé dans `Cert:\CurrentUser\My` (aucun secret) ;
  - connexion directe en mode application lors des lancements suivants ;
  - tenants source et cible connectés simultanément, dans des contextes séparés.
- `Get-EESConnectionStatus`, `Disconnect-EESTenant`, `Remove-EESTenantApp` (suppression de l'application, purge de la corbeille Entra ID et suppression du certificat local).
- Configuration sans secret dans `%APPDATA%\EES.MailboxMigration\tenants.json`.
- Couche HTTP commune : reprise sur 429/502/503/504 avec `Retry-After` et backoff exponentiel, erreurs explicites, URL pré-authentifiées jamais journalisées.
- Journalisation horodatée par exécution (`Logs/`), niveaux INFO/WARN/ERROR.
- Tests Pester 5, règles PSScriptAnalyzer et workflow GitHub Actions.
