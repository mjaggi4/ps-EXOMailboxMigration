function Invoke-EESGraphRequest {
    <#
    .SYNOPSIS
        Appelle Microsoft Graph dans le contexte explicite d'un rôle (Source ou Target).
    .DESCRIPTION
        - Jeton app-only (certificat) par défaut, ou jeton délégué de l'administrateur avec -Delegated.
        - Aucune dépendance au contexte global de Connect-MgGraph : les deux tenants coexistent.
        - Reprise automatique (429/5xx) via Invoke-EESRestRequest.
        - 401 : une nouvelle tentative avec un jeton rafraîchi.
        - -All : suit @odata.nextLink et retourne tous les éléments de « value ».
    .PARAMETER Role
        Rôle de la connexion à utiliser.
    .PARAMETER Connection
        Objet de connexion explicite (connexion administrateur temporaire).
    .PARAMETER Method
        Méthode HTTP.
    .PARAMETER Uri
        Chemin relatif (ex. '/users/x@y.com') ou URL absolue (ex. nextLink).
    .PARAMETER Body
        Corps : objet (sérialisé en JSON) ou texte JSON.
    .PARAMETER ApiVersion
        Version de l'API Graph pour les chemins relatifs.
    .PARAMETER Delegated
        Utilise le jeton délégué de l'administrateur connecté.
    .PARAMETER All
        Parcourt toutes les pages de résultats.
    .PARAMETER PassThru
        Retourne { StatusCode, Headers, Content }.
    .PARAMETER Headers
        En-têtes supplémentaires.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Role')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Role')]
        [ValidateSet('Source', 'Target')]
        [string]$Role,

        [Parameter(Mandatory, ParameterSetName = 'Connection')]
        [pscustomobject]$Connection,

        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',

        [Parameter(Mandatory)]
        [string]$Uri,

        [AllowNull()]
        [object]$Body,

        [ValidateSet('v1.0', 'beta')]
        [string]$ApiVersion = 'v1.0',

        [switch]$Delegated,

        [switch]$All,

        [switch]$PassThru,

        [hashtable]$Headers
    )

    $nextUri = if ($Uri -match '^https://') {
        $Uri
    }
    else {
        '{0}/{1}/{2}' -f $script:EESConstants.GraphBaseUrl, $ApiVersion, $Uri.TrimStart('/')
    }

    $jsonBody = $null
    if ($null -ne $Body) {
        $jsonBody = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
    }

    $items = [System.Collections.Generic.List[object]]::new()

    while ($nextUri) {
        $refreshed = $false
        while ($true) {
            $tokenParams = @{ Delegated = $Delegated; ForceRefresh = $refreshed }
            if ($PSCmdlet.ParameterSetName -eq 'Connection') {
                $tokenParams.Connection = $Connection
            }
            else {
                $tokenParams.Role = $Role
            }
            $token = Get-EESAccessToken @tokenParams
            $requestHeaders = @{ Authorization = "Bearer $token" }
            if ($Headers) {
                foreach ($key in $Headers.Keys) {
                    $requestHeaders[$key] = $Headers[$key]
                }
            }
            $restParams = @{
                Method   = $Method
                Uri      = $nextUri
                Headers  = $requestHeaders
                PassThru = $true
            }
            if ($null -ne $jsonBody) {
                $restParams.Body = $jsonBody
            }
            try {
                $response = Invoke-EESRestRequest @restParams
                break
            }
            catch {
                $status = $_.Exception.Data['StatusCode']
                if ($status -eq 401 -and -not $refreshed) {
                    Write-EESLog -Level DEBUG -Message 'HTTP 401 : rafraîchissement du jeton puis nouvelle tentative.'
                    $refreshed = $true
                    continue
                }
                throw
            }
        }

        if (-not $All) {
            if ($PassThru) {
                return $response
            }
            return $response.Content
        }

        $content = $response.Content
        if ($null -ne $content -and $content.PSObject.Properties['value']) {
            foreach ($item in @($content.value)) {
                $items.Add($item)
            }
        }
        $nextUri = if ($null -ne $content -and $content.PSObject.Properties['@odata.nextLink']) { [string]$content.'@odata.nextLink' } else { $null }
    }

    # Les éléments sont émis un par un : l'appelant utilise @(...) pour obtenir un tableau.
    return $items.ToArray()
}
