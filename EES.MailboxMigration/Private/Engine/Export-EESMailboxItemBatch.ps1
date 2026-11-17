function Export-EESMailboxItemBatch {
    <#
    .SYNOPSIS
        Exporte des éléments (flux opaque pleine fidélité) via exportItems regroupés en $batch.
    .DESCRIPTION
        - Lots de 20 éléments au plus et de taille cumulée limitée (Split-EESExportChunk).
        - Jusqu'à 4 lots par requête $batch (limite de 4 requêtes simultanées par boîte).
        - Sous-requêtes 429/502/503/504 : relancées après Retry-After.
        - Sous-requête en erreur définitive sur un lot de plusieurs éléments : le lot est éclaté
          en éléments individuels pour isoler l'élément fautif.
        - ErrorArchiveFolderMovedPermanently (archive auxiliaire) : nouvel export à l'URL indiquée.
        Le flux exporté n'est jamais analysé.
    .PARAMETER Mailbox
        Boîte source résolue.
    .PARAMETER Item
        Éléments à exporter (SourceItemId, Size).
    .PARAMETER MaxRetries
        Nombre maximal de relances d'un lot.
    .OUTPUTS
        Dictionnaire SourceItemId -> { Data, ChangeKey, Error }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, object]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Mailbox,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Item,

        [int]$MaxRetries = 8
    )

    $results = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    if ($Item.Count -eq 0) {
        return , $results
    }

    $exportPath = "/admin/exchange/mailboxes/$($Mailbox.MailboxId)/exportItems"
    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($chunk in (Split-EESExportChunk -Item $Item)) {
        $pending.Enqueue([pscustomobject]@{ Ids = [string[]]@($chunk | ForEach-Object { $_.SourceItemId }); Attempt = 0 })
    }

    $redirects = [System.Collections.Generic.List[object]]::new()
    $redirectedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    while ($pending.Count -gt 0) {
        $wave = [System.Collections.Generic.List[object]]::new()
        while ($pending.Count -gt 0 -and $wave.Count -lt 4) {
            $wave.Add($pending.Dequeue())
        }

        $requests = for ($i = 0; $i -lt $wave.Count; $i++) {
            [ordered]@{
                id      = [string]($i + 1)
                method  = 'POST'
                url     = $exportPath
                headers = @{ 'Content-Type' = 'application/json' }
                body    = @{ itemIds = @($wave[$i].Ids) }
            }
        }
        $batchResponse = Invoke-EESGraphRequest -Role Source -Method POST -Uri '/$batch' -ApiVersion $Mailbox.ApiVersion -Body @{ requests = @($requests) }

        $waitSeconds = 0.0
        foreach ($response in @($batchResponse.responses)) {
            $chunk = $wave[[int]$response.id - 1]
            $status = [int]$response.status

            if ($status -eq 200) {
                foreach ($exported in @($response.body.value)) {
                    $itemId = [string]$exported.itemId
                    $errorInfo = if ($exported.PSObject.Properties['error'] -and $exported.error) { $exported.error } elseif ($exported.PSObject.Properties['Error'] -and $exported.Error) { $exported.Error } else { $null }
                    if ($errorInfo) {
                        if ($errorInfo.code -eq 'ErrorArchiveFolderMovedPermanently' -and $errorInfo.message -match '^https://') {
                            $redirects.Add([pscustomobject]@{ Url = [string]$errorInfo.message; ItemId = $itemId })
                            $null = $redirectedIds.Add($itemId)
                            continue
                        }
                        $results[$itemId] = [pscustomobject]@{ Data = $null; ChangeKey = $null; Error = "$($errorInfo.code) : $($errorInfo.message)" }
                    }
                    else {
                        $results[$itemId] = [pscustomobject]@{ Data = [string]$exported.data; ChangeKey = [string]$exported.changeKey; Error = $null }
                    }
                }
                # Éléments demandés mais absents de la réponse.
                foreach ($id in $chunk.Ids) {
                    if (-not $results.ContainsKey($id) -and -not $redirectedIds.Contains($id)) {
                        $results[$id] = [pscustomobject]@{ Data = $null; ChangeKey = $null; Error = 'Élément absent de la réponse d''export (supprimé entre-temps ?)' }
                    }
                }
                continue
            }

            $message = if ($response.body -and $response.body.PSObject.Properties['error']) { "$($response.body.error.code) : $($response.body.error.message)" } else { "HTTP $status" }

            if ((Test-EESRetryableStatusCode -StatusCode $status) -and $chunk.Attempt -lt $MaxRetries) {
                $chunk.Attempt++
                $retryAfter = Get-EESHeaderValue -Headers (ConvertTo-EESHashtable -InputObject $response.headers) -Name 'Retry-After'
                $waitSeconds = [math]::Max($waitSeconds, (Get-EESRetryDelay -Attempt $chunk.Attempt -RetryAfter $retryAfter))
                $pending.Enqueue($chunk)
                continue
            }

            if ($chunk.Ids.Count -gt 1 -and -not (Test-EESRetryableStatusCode -StatusCode $status)) {
                # Isole l'élément fautif.
                foreach ($id in $chunk.Ids) {
                    $pending.Enqueue([pscustomobject]@{ Ids = [string[]]@($id); Attempt = $chunk.Attempt })
                }
                continue
            }

            foreach ($id in $chunk.Ids) {
                $results[$id] = [pscustomobject]@{ Data = $null; ChangeKey = $null; Error = "Export impossible : $message" }
            }
        }

        if ($waitSeconds -gt 0) {
            Write-EESLog -Level DEBUG -Message ("Export : limitation de débit, pause de {0:N1} s." -f $waitSeconds) -Context $Mailbox.Identity
            Start-Sleep -Milliseconds ([int]($waitSeconds * 1000))
        }
    }

    # Archive auxiliaire : export direct à l'URL indiquée par le service.
    foreach ($group in ($redirects | Group-Object -Property Url)) {
        $ids = [string[]]@($group.Group.ItemId)
        try {
            $response = Invoke-EESGraphRequest -Role Source -Method POST -Uri $group.Name -Body @{ itemIds = @($ids) }
            foreach ($exported in @($response.value)) {
                $errorInfo = if ($exported.PSObject.Properties['error'] -and $exported.error) { $exported.error } else { $null }
                $results[[string]$exported.itemId] = if ($errorInfo) {
                    [pscustomobject]@{ Data = $null; ChangeKey = $null; Error = "$($errorInfo.code) : $($errorInfo.message)" }
                }
                else {
                    [pscustomobject]@{ Data = [string]$exported.data; ChangeKey = [string]$exported.changeKey; Error = $null }
                }
            }
        }
        catch {
            foreach ($id in $ids) {
                $results[$id] = [pscustomobject]@{ Data = $null; ChangeKey = $null; Error = "Export (archive auxiliaire) impossible : $($_.Exception.Message)" }
            }
        }
    }

    return , $results
}
