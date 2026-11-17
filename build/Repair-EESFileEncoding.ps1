#Requires -Version 7.4
<#
.SYNOPSIS
    Convertit les scripts PowerShell du dépôt en UTF-8 avec BOM.
.DESCRIPTION
    Le BOM est nécessaire pour que Windows PowerShell 5.1 (installeur) lise correctement les
    caractères accentués, et il est exigé par la règle PSScriptAnalyzer PSUseBOMForUnicodeEncodedFile.
    Le script est idempotent.
.PARAMETER Path
    Racine du dépôt.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path = (Split-Path -Path $PSScriptRoot -Parent)
)

$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$extensions = @('.ps1', '.psm1', '.psd1')

Get-ChildItem -LiteralPath $Path -Recurse -File |
    Where-Object { $extensions -contains $_.Extension -and $_.FullName -notmatch '[\\/]\.git[\\/]' } |
    ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom -and $PSCmdlet.ShouldProcess($_.FullName, 'Convertir en UTF-8 avec BOM')) {
            $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
            [System.IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
            Write-Verbose -Message "BOM ajouté : $($_.FullName)"
        }
    }
