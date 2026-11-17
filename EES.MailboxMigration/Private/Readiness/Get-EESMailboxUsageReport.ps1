function Get-EESMailboxUsageReport {
    <#
    .SYNOPSIS
        Retourne le rapport d'utilisation des boîtes d'un tenant (taille, nombre d'éléments, quotas).
    .DESCRIPTION
        GET /reports/getMailboxUsageDetail(period='D7') répond par une redirection (302) vers une URL
        pré-authentifiée qui doit être appelée SANS en-tête Authorization : la redirection est donc
        suivie manuellement. Données mises à jour par Microsoft avec 24 à 48 h de décalage.
        Si le tenant masque les noms dans les rapports (paramètre « Afficher les noms d'utilisateur
        masqués »), les UPN sont anonymisés et le rapport ne peut pas être exploité.
        Résultat mis en cache 30 minutes par rôle.
    .PARAMETER Role
        Tenant concerné.
    .OUTPUTS
        Hashtable : UPN en minuscules -> ligne du rapport.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Source', 'Target')]
        [string]$Role
    )

    if (-not $script:EESUsageReports) {
        $script:EESUsageReports = @{}
    }
    $cached = $script:EESUsageReports[$Role]
    if ($cached -and $cached.LoadedAt -gt (Get-Date).AddMinutes(-30)) {
        return $cached.Data
    }

    $uri = "$($script:EESConstants.GraphBaseUrl)/v1.0/reports/getMailboxUsageDetail(period='D7')"
    $location = $null
    for ($attempt = 1; $attempt -le 6 -and -not $location; $attempt++) {
        $token = Get-EESAccessToken -Role $Role
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        try {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308) -and $response.Headers.Location) {
                $location = $response.Headers.Location.AbsoluteUri
            }
            elseif (Test-EESRetryableStatusCode -StatusCode $status) {
                $retryAfter = if ($response.Headers.RetryAfter -and $response.Headers.RetryAfter.Delta) { [string][int]$response.Headers.RetryAfter.Delta.Value.TotalSeconds } else { $null }
                Start-Sleep -Milliseconds ([int]((Get-EESRetryDelay -Attempt $attempt -RetryAfter $retryAfter) * 1000))
            }
            else {
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $content = try { $body | ConvertFrom-Json -ErrorAction Stop } catch { $body }
                throw (ConvertTo-EESHttpException -Method GET -Uri $uri -StatusCode $status -Content $content)
            }
        }
        finally {
            $client.Dispose()
        }
    }
    if (-not $location) {
        throw "Rapport d'utilisation des boîtes indisponible ($Role) après plusieurs tentatives."
    }

    # URL pré-authentifiée : pas d'en-tête Authorization.
    $csv = Invoke-EESRestRequest -Method GET -Uri $location
    if ($csv -is [byte[]]) {
        $csv = [System.Text.Encoding]::UTF8.GetString($csv)
    }
    $csv = ([string]$csv).TrimStart([char]0xFEFF)

    $data = @{}
    foreach ($row in @($csv | ConvertFrom-Csv)) {
        $upn = [string]$row.'User Principal Name'
        if ($upn) {
            $data[$upn.ToLowerInvariant()] = $row
        }
    }
    $script:EESUsageReports[$Role] = [pscustomobject]@{ LoadedAt = Get-Date; Data = $data }
    return $data
}
