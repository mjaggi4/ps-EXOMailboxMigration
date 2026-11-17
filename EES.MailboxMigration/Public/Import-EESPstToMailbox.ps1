function Import-EESPstToMailbox {
    <#
    .SYNOPSIS
        Importe un ou plusieurs fichiers PST dans une boîte Exchange Online (service d'import Microsoft Purview).

    .DESCRIPTION
        Méthode NetworkUpload (par défaut, méthode documentée de Microsoft) :
          1. Vérifie les fichiers PST (noms uniques, taille conseillée ≤ 20 Go).
          2. Télécharge AzCopy si besoin (version officielle Microsoft, signature vérifiée).
          3. Téléverse les PST avec l'URL SAS copiée depuis le portail Purview
             (Gestion du cycle de vie des données > Microsoft 365 > Importer > Nouveau travail
             d'importation > Charger vos données > Afficher l'URL SAS de chargement réseau).
          4. Génère le fichier de mappage CSV au format exact attendu par Purview.
          5. Affiche les étapes restantes à faire dans le portail (création du travail, validation du
             mappage, analyse puis import). La création du travail d'import n'est pas automatisable :
             Microsoft ne prend pas en charge PowerShell pour cette étape.
        Prérequis : rôle « Mailbox Import Export » pour le compte qui crée le travail dans Purview.
        Après import, Microsoft active la conservation (RetentionHoldEnabled) sur la boîte.

        Méthode AzurePstImport : nouvelle fonctionnalité Purview annoncée (déploiement prévu
        fin mars – fin avril 2027) dont les cmdlets ne sont pas encore documentées publiquement.
        Le module détecte sa disponibilité et l'indique clairement, sans rien modifier.

    .PARAMETER PstPath
        Fichier(s) PST, ou dossier(s) contenant des PST (non récursif).

    .PARAMETER TargetMailbox
        Adresse de la boîte de destination.

    .PARAMETER Method
        NetworkUpload (défaut) ou AzurePstImport.

    .PARAMETER TargetRootFolder
        Dossier de la boîte où importer le contenu (ex. « Import PST »). Par défaut, le contenu est
        fusionné dans les dossiers existants (valeur « / » du mappage Purview).

    .PARAMETER IsArchive
        Importe dans la boîte d'archive (qui doit être activée ; 100 Go maximum par import).

    .PARAMETER SasUrl
        URL SAS de chargement réseau copiée depuis le portail Purview. Si elle est absente, elle est
        demandée de façon masquée. Elle n'est jamais écrite dans les logs.

    .PARAMETER AzCopyPath
        Chemin d'azcopy.exe (sinon téléchargé automatiquement).

    .PARAMETER MappingPath
        Dossier où écrire le fichier de mappage. Par défaut : dossier Reports.

    .PARAMETER MappingOnly
        Génère seulement le fichier de mappage (PST déjà téléversés avec le même sous-dossier).

    .PARAMETER UploadFolder
        Sous-dossier de dépôt dans le stockage Purview (défaut : EES-<date>). À réutiliser avec
        -MappingOnly.

    .EXAMPLE
        Import-EESPstToMailbox -PstPath D:\PST\jdupont.pst -TargetMailbox jean.dupont@fabrikam.com

        Téléverse le PST (l'URL SAS est demandée) et génère le fichier de mappage.

    .EXAMPLE
        Import-EESPstToMailbox -PstPath D:\PST\Archives -TargetMailbox jean.dupont@fabrikam.com -IsArchive -TargetRootFolder 'Archives PST'

        Importe tous les PST du dossier dans la boîte d'archive, sous « Archives PST ».

    .EXAMPLE
        Import-EESPstToMailbox D:\PST\jdupont.pst jean.dupont@fabrikam.com -WhatIf

        Affiche le contenu du fichier de mappage sans rien téléverser.

    .OUTPUTS
        EES.PstImportResult

    .LINK
        Export-EESMailboxToPst
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$PstPath,

        [Parameter(Mandatory, Position = 1)]
        [ValidatePattern('^[^@\s,]+@[^@\s,]+$')]
        [string]$TargetMailbox,

        [ValidateSet('NetworkUpload', 'AzurePstImport')]
        [string]$Method = 'NetworkUpload',

        [string]$TargetRootFolder,

        [switch]$IsArchive,

        [string]$SasUrl,

        [string]$AzCopyPath,

        [string]$MappingPath,

        [switch]$MappingOnly,

        [ValidatePattern('^[A-Za-z0-9\-_]+$')]
        [string]$UploadFolder = ('EES-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    )

    if ($Method -eq 'AzurePstImport') {
        $detection = Test-EESAzurePstImport
        Write-EESMessage -Type Warning -Message $detection.Message
        return [pscustomobject]@{
            PSTypeName    = 'EES.PstImportResult'
            Method        = $Method
            TargetMailbox = $TargetMailbox
            Status        = 'NotAvailable'
            Files         = @()
            UploadFolder  = $null
            MappingFiles  = @()
            Message       = $detection.Message
        }
    }

    # --- 1. Fichiers PST ----------------------------------------------------------------------------
    $files = foreach ($item in $PstPath) {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($item)
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            Get-ChildItem -LiteralPath $resolved -Filter '*.pst' -File
        }
        elseif (Test-Path -LiteralPath $resolved -PathType Leaf) {
            Get-Item -LiteralPath $resolved
        }
        else {
            throw "Fichier ou dossier introuvable : $resolved"
        }
    }
    $files = @($files | Sort-Object -Property FullName)
    if ($files.Count -eq 0) {
        throw 'Aucun fichier PST trouvé.'
    }
    foreach ($file in $files) {
        if ($file.Extension -ne '.pst') {
            throw "Ce n'est pas un fichier PST : $($file.FullName)"
        }
        if ($file.Name -match '[;,"]') {
            throw "Nom de fichier non pris en charge (caractères interdits : point-virgule, virgule, guillemet) : $($file.Name). Renommez le fichier."
        }
        if ($file.Length -gt 20GB) {
            Write-EESMessage -Type Warning -Message ("{0} fait {1:N1} Go : Microsoft conseille des PST de 20 Go au maximum (import plus lent)." -f $file.Name, ($file.Length / 1GB))
        }
    }
    $duplicates = @($files | Group-Object -Property { $_.Name.ToLowerInvariant() } | Where-Object Count -GT 1)
    if ($duplicates.Count -gt 0) {
        throw "Les noms de PST doivent être uniques : $($duplicates.Name -join ', '). Renommez les doublons."
    }
    $totalGB = [math]::Round((($files | Measure-Object -Property Length -Sum).Sum) / 1GB, 2)

    # --- 2. Mappage -----------------------------------------------------------------------------------
    $root = ConvertTo-EESPurviewRootFolder -TargetRootFolder $TargetRootFolder
    $entries = foreach ($file in $files) {
        [pscustomobject]@{ FilePath = $UploadFolder; Name = $file.Name; Mailbox = $TargetMailbox; IsArchive = [bool]$IsArchive; TargetRootFolder = $root }
    }
    $mappings = @(ConvertTo-EESPstMappingCsv -Entry @($entries))

    $action = if ($MappingOnly) { 'Générer le fichier de mappage Purview' } else { "Téléverser $($files.Count) PST ($totalGB Go) vers le stockage d'import Purview et générer le fichier de mappage" }
    if (-not $PSCmdlet.ShouldProcess($TargetMailbox, $action)) {
        Write-EESMessage -Type Title -Message 'Aperçu du fichier de mappage :'
        foreach ($line in $mappings[0]) {
            Write-EESMessage -Message $line
        }
        return
    }

    # --- 3. Téléversement -----------------------------------------------------------------------------
    if (-not $MappingOnly) {
        if (-not $SasUrl) {
            if (-not [Environment]::UserInteractive) {
                throw 'Indiquez l''URL SAS avec -SasUrl.'
            }
            $secure = Read-Host -Prompt 'Collez l''URL SAS de chargement réseau (portail Purview > Importer)' -AsSecureString
            $SasUrl = ConvertFrom-SecureString -SecureString $secure -AsPlainText
        }
        $destination = Get-EESSasUploadUri -SasUrl $SasUrl -Folder $UploadFolder
        $azcopy = Get-EESAzCopy -Path $AzCopyPath

        $env:AZCOPY_LOG_LOCATION = Join-Path -Path (Get-EESPath -Kind Logs) -ChildPath 'azcopy'
        $env:AZCOPY_JOB_PLAN_LOCATION = Join-Path -Path (Get-EESPath -Kind Tools) -ChildPath 'azcopy-plans'

        foreach ($group in ($files | Group-Object -Property DirectoryName)) {
            $pattern = ($group.Group.Name) -join ';'
            $source = Join-Path -Path $group.Name -ChildPath '*'
            Write-EESMessage -Message ("Téléversement de {0} fichier(s) depuis {1} vers {2}..." -f $group.Count, $group.Name, (ConvertTo-EESSafeUri -Uri $destination))
            Write-EESLog -Message "AzCopy : $($group.Group.Name -join ', ') -> $(ConvertTo-EESSafeUri -Uri $destination)"
            & $azcopy copy $source $destination --include-pattern $pattern --log-level=WARNING
            if ($LASTEXITCODE -ne 0) {
                throw "AzCopy a échoué (code $LASTEXITCODE). Consultez les logs AzCopy dans $($env:AZCOPY_LOG_LOCATION), puis relancez la commande."
            }
        }
        Write-EESMessage -Type Success -Message "Téléversement terminé dans le sous-dossier « $UploadFolder »."
    }

    # --- 4. Fichier(s) de mappage ---------------------------------------------------------------------
    $directory = if ($MappingPath) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MappingPath) } else { Get-EESPath -Kind Reports }
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }
    $mappingFiles = for ($i = 0; $i -lt $mappings.Count; $i++) {
        $suffix = if ($mappings.Count -gt 1) { "_$($i + 1)" } else { '' }
        $file = Join-Path -Path $directory -ChildPath "PST-Mapping_$UploadFolder$suffix.csv"
        [System.IO.File]::WriteAllLines($file, [string[]]$mappings[$i], [System.Text.UTF8Encoding]::new($false))
        $file
    }

    # --- 5. Étapes restantes ----------------------------------------------------------------------------
    $steps = @(
        'Étapes restantes dans le portail Microsoft Purview (https://purview.microsoft.com) :'
        '  1. Solutions > Gestion du cycle de vie des données > Microsoft 365 > Importer > Nouveau travail d''importation.'
        '  2. Nom du travail en minuscules, sans espace ; choisir « Charger vos données ».'
        '  3. Cocher « J''ai terminé de charger mes fichiers » et « J''ai accès au fichier de mappage ».'
        "  4. Sélectionner le fichier de mappage : $($mappingFiles -join ' ; ') puis « Valider »."
        '  5. Accepter les conditions et enregistrer : l''analyse démarre (« Analyse en cours »).'
        '  6. Quand le statut est « Analyse terminée » : « Importer dans Office 365 », filtrer si besoin, puis lancer l''import.'
        '  Remarque : Microsoft active ensuite la conservation (RetentionHoldEnabled) sur la boîte ; désactivez-la plus tard si nécessaire.'
    )
    foreach ($line in $steps) {
        Write-EESMessage -Type Title -Message $line
    }

    return [pscustomobject]@{
        PSTypeName    = 'EES.PstImportResult'
        Method        = $Method
        TargetMailbox = $TargetMailbox
        Status        = if ($MappingOnly) { 'MappingGenerated' } else { 'Uploaded' }
        Files         = @($files.FullName)
        UploadFolder  = $UploadFolder
        MappingFiles  = @($mappingFiles)
        Message       = 'Terminez l''import dans le portail Purview (étapes affichées).'
    }
}
