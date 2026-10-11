@{
    ExcludeRules = @(
        # The script is an interactive, colored report: Write-Host is the point.
        'PSAvoidUsingWriteHost'
        # Cleaning has its own per-item confirmation and -DryRun instead of -WhatIf.
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
