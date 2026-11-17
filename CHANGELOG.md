# Journal des modifications

Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/). Versionnage sémantique.

## [Non publié]

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
