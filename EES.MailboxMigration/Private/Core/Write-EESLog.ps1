function Write-EESLog {
    <#
    .SYNOPSIS
        Écrit une ligne dans le fichier log horodaté de l'exécution et dans le flux PowerShell adapté.
    .DESCRIPTION
        Un fichier log est créé par exécution dans le dossier Logs (EES_aaaaMMjj_HHmmss_<PID>.log).
        Les runspaces parallèles partagent le même fichier via la variable d'environnement
        EES_MAILBOXMIGRATION_LOGFILE.
        INFO  -> Write-Verbose (visible avec -Verbose)
        WARN  -> Write-Warning
        ERROR -> Write-Warning préfixé (l'appelant décide de lever l'erreur)
        DEBUG -> Write-Debug
    .PARAMETER Message
        Message à journaliser. Ne jamais y mettre de jeton ni d'URL pré-authentifiée.
    .PARAMETER Level
        Niveau : DEBUG, INFO, WARN, ERROR.
    .PARAMETER Context
        Contexte facultatif (ex. adresse de la boîte en cours).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [string]$Context
    )

    if (-not $script:EESLogFile) {
        if ($env:EES_MAILBOXMIGRATION_LOGFILE) {
            $script:EESLogFile = $env:EES_MAILBOXMIGRATION_LOGFILE
        }
        else {
            $fileName = 'EES_{0:yyyyMMdd_HHmmss}_{1}.log' -f (Get-Date), $PID
            $script:EESLogFile = Join-Path -Path (Get-EESPath -Kind Logs) -ChildPath $fileName
        }
    }

    $prefix = if ($Context) { "[$Context] " } else { '' }
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1,-5}] {2}{3}' -f (Get-Date), $Level, $prefix, $Message

    # Écriture tolérante aux accès concurrents (plusieurs runspaces sur le même fichier).
    for ($try = 1; $try -le 5; $try++) {
        try {
            [System.IO.File]::AppendAllText($script:EESLogFile, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
            break
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds (20 * $try)
        }
        catch {
            Write-Debug -Message "Écriture du log impossible : $($_.Exception.Message)"
            break
        }
    }

    switch ($Level) {
        'DEBUG' { Write-Debug -Message $Message }
        'INFO' { Write-Verbose -Message "$prefix$Message" }
        'WARN' { Write-Warning -Message "$prefix$Message" }
        'ERROR' { Write-Warning -Message "ERREUR : $prefix$Message" }
    }
}
