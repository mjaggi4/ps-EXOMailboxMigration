@{
    # Analyse stricte : aucune erreur ni aucun avertissement toléré (voir .github/workflows/ci.yml).
    Severity     = @('Error', 'Warning')
    IncludeDefaultRules = $true
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.4')
        }
    }
}
