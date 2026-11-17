function Wait-EESEDiscoveryOperation {
    <#
    .SYNOPSIS
        Attend la fin d'une opération eDiscovery (estimation, export) en affichant la progression.
    .PARAMETER Connection
        Connexion déléguée eDiscovery.
    .PARAMETER OperationUri
        URL de l'opération (en-tête Location de la réponse 202).
    .PARAMETER Activity
        Libellé de la barre de progression.
    .PARAMETER PollSeconds
        Intervalle d'interrogation.
    .PARAMETER TimeoutHours
        Délai maximal.
    .OUTPUTS
        L'opération terminée (status succeeded ou partiallySucceeded).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Connection,

        [Parameter(Mandatory)]
        [string]$OperationUri,

        [Parameter(Mandatory)]
        [string]$Activity,

        [int]$PollSeconds = 20,

        [int]$TimeoutHours = 48
    )

    $deadline = (Get-Date).AddHours($TimeoutHours)
    while ((Get-Date) -lt $deadline) {
        $operation = Invoke-EESGraphRequest -Connection $Connection -Delegated -Uri $OperationUri
        $status = [string]$operation.status
        $percent = [int]$operation.percentProgress
        Write-Progress -Id 3 -Activity $Activity -Status "$status ($percent %)" -PercentComplete ([math]::Min(100, [math]::Max(0, $percent)))

        switch ($status) {
            { $_ -in @('succeeded', 'partiallySucceeded') } {
                Write-Progress -Id 3 -Activity $Activity -Completed
                if ($status -eq 'partiallySucceeded') {
                    Write-EESMessage -Type Warning -Message "$Activity : terminé partiellement."
                }
                return $operation
            }
            { $_ -in @('failed', 'submissionFailed') } {
                Write-Progress -Id 3 -Activity $Activity -Completed
                $detail = if ($operation.resultInfo) { "$($operation.resultInfo.code) $($operation.resultInfo.message)" } else { '' }
                throw "$Activity : échec ($status). $detail"
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    throw "$Activity : délai dépassé ($TimeoutHours h)."
}
