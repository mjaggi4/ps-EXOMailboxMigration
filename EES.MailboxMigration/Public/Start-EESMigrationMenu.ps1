function Start-EESMigrationMenu {
    <#
    .SYNOPSIS
        Ouvre le menu interactif de migration (point d'entrée recommandé pour l'administrateur).

    .DESCRIPTION
        Menu en français qui guide pas à pas : connexion des tenants source et cible, pré-vérifications,
        migration d'une boîte ou d'un lot (CSV), passe incrémentale avant bascule MX, suivi et rapports,
        export et import PST, nettoyage en fin de projet.
        Chaque action pose les questions nécessaires puis appelle la commande correspondante du module
        (voir Get-Command -Module EES.MailboxMigration). Les erreurs sont affichées sans quitter le menu.

    .EXAMPLE
        Start-EESMigrationMenu

        Ouvre le menu.

    .LINK
        Connect-EESTenant

    .LINK
        Start-EESMailboxMigration
    #>
    # Nom imposé par le cahier des charges ; le menu ne modifie rien lui-même : chaque action appelle
    # une commande publique qui gère -WhatIf / -Confirm et demande confirmation dans le menu.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param()

    $items = [ordered]@{
        '1'  = 'Connecter le tenant SOURCE'
        '2'  = 'Connecter le tenant CIBLE'
        '3'  = 'État des connexions'
        '4'  = 'Pré-vérifications (une boîte ou un fichier CSV)'
        '5'  = 'Migrer une boîte'
        '6'  = 'Migrer un lot (CSV) / créer un modèle CSV'
        '7'  = 'Passe incrémentale d''une boîte (avant bascule MX)'
        '8'  = 'Suivi des migrations et rapport HTML'
        '9'  = 'Exporter une boîte en PST'
        '10' = 'Importer un PST dans une boîte'
        '11' = 'Fin de projet : supprimer l''application d''un tenant'
        '0'  = 'Quitter'
    }

    while ($true) {
        Write-EESMessage -Message ''
        Write-EESMessage -Type Title -Message '=== EES.MailboxMigration – migration de boîtes Exchange Online ==='
        foreach ($status in @(Get-EESConnectionStatus)) {
            $label = if ($status.Role -eq 'Source') { 'Source' } else { 'Cible ' }
            $type = if ($status.Connected) { 'Success' } else { 'Warning' }
            $tenant = if ($status.TenantName) { "$($status.TenantName) – " } else { '' }
            Write-EESMessage -Type $type -Message "  $label : $tenant$($status.Status)"
        }
        Write-EESMessage -Message ''
        foreach ($key in $items.Keys) {
            Write-EESMessage -Message ('  {0,2}. {1}' -f $key, $items[$key])
        }

        $choice = Read-EESInput -Prompt 'Votre choix'
        if ($choice -eq '0') {
            Write-EESMessage -Message 'Au revoir.'
            return
        }
        if (-not $items.Contains($choice)) {
            Write-EESMessage -Type Warning -Message "Choix inconnu : « $choice »."
            continue
        }

        try {
            Invoke-EESMenuAction -Choice $choice
        }
        catch {
            Write-EESMessage -Type Warning -Message "Erreur : $($_.Exception.Message)"
        }
        $null = Read-EESInput -Prompt 'Appuyez sur Entrée pour revenir au menu'
    }
}
