function ConvertTo-EESHashtable {
    <#
    .SYNOPSIS
        Convertit un objet simple (PSCustomObject issu de JSON) en hashtable (un seul niveau).
    .PARAMETER InputObject
        Objet à convertir.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    $table = @{}
    if ($null -eq $InputObject) {
        return $table
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $table[[string]$key] = $InputObject[$key]
        }
        return $table
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }
    return $table
}
