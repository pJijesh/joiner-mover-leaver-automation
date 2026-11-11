@{
    RootModule            = 'JmlAutomation.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = '6f0b2d52-3c1e-4c8a-9a57-0d1e4f7b2a91'
    Author                = 'Puliyappottammal Jijesh'
    CompanyName           = 'Puliyappottammal Jijesh'
    Copyright             = '(c) 2026 Puliyappottammal Jijesh. MIT licence.'
    Description           = 'Joiner, mover and leaver automation for Microsoft Entra ID using the Microsoft Graph PowerShell SDK. Dry run by default, with a structured audit log.'
    PowerShellVersion     = '7.2'
    CompatiblePSEditions  = @('Core')
    FunctionsToExport     = @(
        'Connect-JmlGraph',
        'New-JmlJoiner',
        'Move-JmlUser',
        'Remove-JmlLeaver',
        'Invoke-JmlBatch'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags       = @('EntraID', 'MicrosoftGraph', 'Joiner', 'Mover', 'Leaver', 'IdentityLifecycle', 'Automation')
            LicenseUri = 'https://github.com/pJijesh/joiner-mover-leaver-automation/blob/main/LICENSE'
            ProjectUri = 'https://github.com/pJijesh/joiner-mover-leaver-automation'
        }
    }
}
