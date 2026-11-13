# PSScriptAnalyzer settings for install.ps1 and its tests (deploy-init-plan.md
# §1.1, D7 9.1 item 8): every rule of severity Warning and Error, minus the
# exclusions below, each with its reason.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The installer's what-if is its own -DryRun switch; its internal
        # functions (New-Folder, Set-RegistryValue, ...) do not take
        # -WhatIf/-Confirm.
        'PSUseShouldProcessForStateChangingFunctions',
        # Names such as Get-OsFacts, Test-ActiveHours, Invoke-InstallSteps
        # describe one set of facts or steps; singular nouns would mislead.
        'PSUseSingularNouns'
    )
}
