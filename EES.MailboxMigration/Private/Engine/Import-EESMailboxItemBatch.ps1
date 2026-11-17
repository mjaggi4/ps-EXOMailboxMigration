function Import-EESMailboxItemBatch {
    <#
    .SYNOPSIS
        Importe des éléments exportés dans la boîte cible (POST sur l'importUrl, non batchable).
    .DESCRIPTION
        - Jusqu'à -Concurrency requêtes simultanées (4 au plus : limite par boîte).
        - 429/502/503/504 et erreurs réseau : pause globale (Retry-After) puis nouvelle tentative.
        - 401/403 : nouvelle session d'import (expiration du jeton embarqué), une fois.
        - 409 (archive auxiliaire) : nouvelle session sur la boîte indiquée, une fois.
        - Autres erreurs : l'élément est marqué en échec, sans interrompre les autres.
    .PARAMETER Mailbox
        Boîte cible résolue.
    .PARAMETER Entry
        Éléments : { SourceItemId, FolderId, Data, TargetItemId, TargetChangeKey }.
    .PARAMETER Concurrency
        Nombre d'imports simultanés.
    .PARAMETER MaxRetries
        Nombre maximal de nouvelles tentatives par élément.
    .OUTPUTS
        Dictionnaire SourceItemId -> { TargetItemId, TargetChangeKey, TargetMailboxId, Error }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, object]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Mailbox,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entry,

        [ValidateRange(1, 4)]
        [int]$Concurrency = 4,

        [int]$MaxRetries = 8
    )

    $results = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    if ($Entry.Count -eq 0) {
        return , $results
    }

    $client = Get-EESHttpClient
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($e in $Entry) {
        $queue.Enqueue([pscustomobject]@{
                Entry          = $e
                Attempt        = 0
                MailboxId      = if ($e.PSObject.Properties['TargetMailboxId'] -and $e.TargetMailboxId) { $e.TargetMailboxId } else { $Mailbox.MailboxId }
                ForceSession   = $false
                SessionRenewed = $false
                Redirected     = $false
            })
    }
    $inflight = [System.Collections.Generic.List[object]]::new()
    $pauseUntil = [datetime]::MinValue

    $fail = {
        param($work, [string]$message)
        $results[[string]$work.Entry.SourceItemId] = [pscustomobject]@{
            TargetItemId = $null; TargetChangeKey = $null; TargetMailboxId = $work.MailboxId; Error = $message
        }
    }

    while ($queue.Count -gt 0 -or $inflight.Count -gt 0) {
        # Démarrage de nouvelles requêtes dans la limite de concurrence.
        while ($inflight.Count -lt $Concurrency -and $queue.Count -gt 0 -and (Get-Date) -ge $pauseUntil) {
            $work = $queue.Dequeue()
            try {
                $session = Get-EESImportSession -Mailbox $Mailbox -MailboxId $work.MailboxId -Force:$work.ForceSession
                $work.ForceSession = $false
                $body = ConvertTo-EESImportBody -FolderId $work.Entry.FolderId -Data $work.Entry.Data -TargetItemId $work.Entry.TargetItemId -TargetChangeKey $work.Entry.TargetChangeKey
            }
            catch {
                & $fail $work $_.Exception.Message
                continue
            }
            $content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
            $inflight.Add([pscustomobject]@{ Work = $work; Task = $client.PostAsync($session.ImportUrl, $content); Content = $content })
        }

        if ($inflight.Count -eq 0) {
            $wait = ($pauseUntil - (Get-Date)).TotalMilliseconds
            if ($wait -gt 0) {
                Start-Sleep -Milliseconds ([int][math]::Min($wait, 60000))
            }
            continue
        }

        $tasks = [System.Threading.Tasks.Task[]]@($inflight | ForEach-Object { $_.Task })
        $index = [System.Threading.Tasks.Task]::WaitAny($tasks, 1000)
        if ($index -lt 0) {
            continue
        }
        $done = $inflight[$index]
        $inflight.RemoveAt($index)
        $work = $done.Work

        $status = 0
        $text = $null
        $retryAfter = $null
        try {
            $response = $done.Task.GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($response.Headers.RetryAfter) {
                $retryAfter = if ($response.Headers.RetryAfter.Delta) {
                    [string][int]$response.Headers.RetryAfter.Delta.Value.TotalSeconds
                }
                elseif ($response.Headers.RetryAfter.Date) {
                    $response.Headers.RetryAfter.Date.Value.ToString('r')
                }
            }
            $response.Dispose()
        }
        catch {
            $text = $_.Exception.GetBaseException().Message
        }
        finally {
            $done.Content.Dispose()
        }

        $parsed = $null
        if ($text) {
            try {
                $parsed = $text | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $parsed = $null
            }
        }

        if ($status -ge 200 -and $status -lt 300 -and $parsed -and $parsed.itemId) {
            $results[[string]$work.Entry.SourceItemId] = [pscustomobject]@{
                TargetItemId    = [string]$parsed.itemId
                TargetChangeKey = [string]$parsed.changeKey
                TargetMailboxId = $work.MailboxId
                Error           = $null
            }
            continue
        }

        $message = if ($parsed -and $parsed.PSObject.Properties['error'] -and $parsed.error) {
            "$($parsed.error.code) : $($parsed.error.message)"
        }
        elseif ($parsed -and $parsed.PSObject.Properties['Message']) {
            [string]$parsed.Message
        }
        elseif ($text) {
            $text.Substring(0, [math]::Min($text.Length, 500))
        }
        else {
            "HTTP $status"
        }

        if (($status -eq 0 -or (Test-EESRetryableStatusCode -StatusCode $status)) -and $work.Attempt -lt $MaxRetries) {
            $work.Attempt++
            $delay = Get-EESRetryDelay -Attempt $work.Attempt -RetryAfter $retryAfter
            $candidate = (Get-Date).AddSeconds($delay)
            if ($candidate -gt $pauseUntil) {
                $pauseUntil = $candidate
            }
            Write-EESLog -Level DEBUG -Message ("Import : HTTP {0}, nouvelle tentative {1}/{2} dans {3:N1} s." -f $status, $work.Attempt, $MaxRetries, $delay) -Context $Mailbox.Identity
            $queue.Enqueue($work)
            continue
        }

        if ($status -in @(401, 403) -and -not $work.SessionRenewed) {
            $work.SessionRenewed = $true
            $work.ForceSession = $true
            $queue.Enqueue($work)
            continue
        }

        if ($status -eq 409 -and -not $work.Redirected) {
            $redirect = Get-EESRedirectMailboxId -Message $message
            if ($redirect) {
                Write-EESLog -Level DEBUG -Message "Import redirigé vers l'archive auxiliaire $redirect." -Context $Mailbox.Identity
                $work.Redirected = $true
                $work.MailboxId = $redirect
                $queue.Enqueue($work)
                continue
            }
        }

        & $fail $work ("Import impossible (HTTP {0}) : {1}" -f $status, $message)
    }

    return , $results
}
