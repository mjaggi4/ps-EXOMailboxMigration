function Invoke-EESOutlookPstExport {
    <#
    .SYNOPSIS
        Exporte une boîte vers un PST avec Outlook classique (COM), méthode de secours.
    .DESCRIPTION
        Prérequis : Windows, Outlook classique (le nouvel Outlook n'a pas d'interface COM) avec un
        profil dans lequel la boîte est accessible (accès total, ajoutée automatiquement ou manuellement).
        Chaque dossier de premier niveau est copié (avec ses sous-dossiers et éléments) dans un PST
        Unicode créé pour l'occasion, puis le PST est détaché du profil. La boîte n'est pas modifiée.
        Méthode lente, à réserver aux tenants où l'export eDiscovery n'est pas utilisable.
    .PARAMETER Mailbox
        Adresse de la boîte.
    .PARAMETER OutputPath
        Dossier de destination.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$Mailbox,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    if (-not $IsWindows) {
        throw 'La méthode Outlook nécessite Windows et Outlook classique.'
    }
    $outlookType = [type]::GetTypeFromProgID('Outlook.Application')
    if (-not $outlookType) {
        throw 'Outlook classique n''est pas installé sur ce poste (le nouvel Outlook ne permet pas l''automatisation). Installez Outlook classique ou utilisez -Method EDiscovery.'
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
    }
    $pstPath = Join-Path -Path (Resolve-Path -LiteralPath $OutputPath).Path -ChildPath ('{0}_{1:yyyyMMdd_HHmmss}.pst' -f (ConvertTo-EESSafeFileName -Name $Mailbox), (Get-Date))

    $outlook = $null
    $namespace = $null
    $pstRoot = $null
    try {
        $outlook = [System.Activator]::CreateInstance($outlookType)
        $namespace = $outlook.GetNamespace('MAPI')
        $namespace.Logon()

        $recipient = $namespace.CreateRecipient($Mailbox)
        if (-not $recipient.Resolve()) {
            throw "Outlook ne trouve pas la boîte $Mailbox dans le carnet d'adresses."
        }
        try {
            # 6 = olFolderInbox ; son parent est la racine de la boîte.
            $inbox = $namespace.GetSharedDefaultFolder($recipient, 6)
            $sourceRoot = $inbox.Parent
        }
        catch {
            throw "Outlook n'a pas accès à la boîte $Mailbox. Donnez au compte du profil Outlook l'accès total (FullAccess) à la boîte, ouvrez-la dans Outlook, puis relancez. Détail : $($_.Exception.Message)"
        }

        # 3 = olStoreUnicode.
        $namespace.AddStoreEx($pstPath, 3)
        $pstStore = $null
        foreach ($store in $namespace.Stores) {
            if ($store.FilePath -eq $pstPath) {
                $pstStore = $store
                break
            }
        }
        if (-not $pstStore) {
            throw "Création du fichier PST impossible : $pstPath"
        }
        $pstRoot = $pstStore.GetRootFolder()

        $folders = @($sourceRoot.Folders)
        $index = 0
        foreach ($folder in $folders) {
            $index++
            $name = [string]$folder.Name
            Write-Progress -Id 5 -Activity "Export PST (Outlook) de $Mailbox" -Status $name -PercentComplete ([int](100 * ($index - 1) / [math]::Max(1, $folders.Count)))
            try {
                $null = $folder.CopyTo($pstRoot)
                Write-EESLog -Message "Dossier copié dans le PST : $name ($($folder.Items.Count) éléments)" -Context $Mailbox
            }
            catch {
                Write-EESLog -Level WARN -Message "Dossier « $name » non copié : $($_.Exception.Message)" -Context $Mailbox
            }
        }
        Write-Progress -Id 5 -Activity "Export PST (Outlook) de $Mailbox" -Completed
    }
    finally {
        if ($namespace -and $pstRoot) {
            try {
                $namespace.RemoveStore($pstRoot)
            }
            catch {
                Write-EESLog -Level WARN -Message "Le PST n'a pas pu être détaché du profil Outlook : $($_.Exception.Message)"
            }
        }
        foreach ($comObject in @($pstRoot, $namespace, $outlook)) {
            if ($comObject) {
                $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($comObject)
            }
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }

    return Get-Item -LiteralPath $pstPath
}
