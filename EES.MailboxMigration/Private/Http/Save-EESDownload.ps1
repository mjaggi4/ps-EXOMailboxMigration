function Save-EESDownload {
    <#
    .SYNOPSIS
        Télécharge un fichier volumineux par flux, avec reprise (en-tête Range) après coupure.
    .DESCRIPTION
        - Écrit dans <fichier>.partial, renommé à la fin.
        - Après une erreur réseau, reprend à l'octet atteint (réponse 206) ; si le serveur ne gère
          pas Range (réponse 200), recommence depuis le début.
        - Les en-têtes sont recalculés à chaque tentative (jeton renouvelé pour les téléchargements longs).
    .PARAMETER Uri
        URL du fichier.
    .PARAMETER GetHeaders
        Script retournant une hashtable d'en-têtes (appelé à chaque tentative).
    .PARAMETER Path
        Fichier de destination.
    .PARAMETER ExpectedSize
        Taille attendue (facultative), pour la progression et le contrôle final.
    .PARAMETER MaxAttempts
        Nombre maximal de tentatives.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [scriptblock]$GetHeaders = { @{} },

        [Parameter(Mandatory)]
        [string]$Path,

        [long]$ExpectedSize = 0,

        [int]$MaxAttempts = 20
    )

    $partial = "$Path.partial"
    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $name = Split-Path -Path $Path -Leaf

    try {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $existing = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { [long]0 }
            if ($ExpectedSize -gt 0 -and $existing -ge $ExpectedSize) {
                break
            }

            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
            foreach ($entry in (& $GetHeaders).GetEnumerator()) {
                $null = $request.Headers.TryAddWithoutValidation([string]$entry.Key, [string]$entry.Value)
            }
            if ($existing -gt 0) {
                $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($existing, $null)
            }

            try {
                $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $status = [int]$response.StatusCode
                if ($status -eq 416 -and $existing -gt 0) {
                    $response.Dispose()
                    break
                }
                if (-not $response.IsSuccessStatusCode) {
                    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    $response.Dispose()
                    $exception = [System.Net.Http.HttpRequestException]::new("Téléchargement de $name : HTTP $status $($body.Substring(0, [math]::Min(300, $body.Length)))")
                    $exception.Data['StatusCode'] = $status
                    throw $exception
                }

                $append = ($status -eq 206)
                if (-not $append) {
                    $existing = 0
                }
                $total = if ($ExpectedSize -gt 0) { $ExpectedSize } elseif ($response.Content.Headers.ContentLength) { $existing + [long]$response.Content.Headers.ContentLength } else { 0 }

                $mode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
                $file = [System.IO.FileStream]::new($partial, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB)
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                try {
                    $buffer = [byte[]]::new(4MB)
                    $written = $existing
                    $lastPercent = -1
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $file.Write($buffer, 0, $read)
                        $written += $read
                        if ($total -gt 0) {
                            $percent = [int](100 * $written / $total)
                            if ($percent -ne $lastPercent) {
                                $lastPercent = $percent
                                Write-Progress -Id 4 -Activity "Téléchargement de $name" -Status ('{0:N0} / {1:N0} Mo' -f ($written / 1MB), ($total / 1MB)) -PercentComplete ([math]::Min(100, $percent))
                            }
                        }
                    }
                }
                finally {
                    $stream.Dispose()
                    $file.Dispose()
                    $response.Dispose()
                }
                break
            }
            catch {
                $status = $_.Exception.Data['StatusCode']
                if ($status -and -not (Test-EESRetryableStatusCode -StatusCode $status) -and $status -ne 401) {
                    throw
                }
                if ($attempt -eq $MaxAttempts) {
                    throw
                }
                $delay = Get-EESRetryDelay -Attempt $attempt -MaxDelaySeconds 60
                Write-EESLog -Level WARN -Message ("Téléchargement de {0} interrompu ({1}) : reprise dans {2:N0} s (tentative {3}/{4})." -f $name, $_.Exception.Message, $delay, $attempt, $MaxAttempts)
                Start-Sleep -Milliseconds ([int]($delay * 1000))
            }
        }
    }
    finally {
        $client.Dispose()
        Write-Progress -Id 4 -Activity "Téléchargement de $name" -Completed
    }

    $size = (Get-Item -LiteralPath $partial).Length
    if ($ExpectedSize -gt 0 -and $size -ne $ExpectedSize) {
        throw "Téléchargement de $name incomplet : $size octets reçus sur $ExpectedSize attendus. Relancez la commande pour reprendre."
    }
    Move-Item -LiteralPath $partial -Destination $Path -Force
    return Get-Item -LiteralPath $Path
}
