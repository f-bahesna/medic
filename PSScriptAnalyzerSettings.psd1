@{
    ExcludeRules = @(
        # The installer and the tests talk to a person: Write-Host is the point.
        'PSAvoidUsingWriteHost'
        # The installer changes only what it installed, and -Uninstall undoes it.
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
