@{
    RootModule        = 'WinAdvisor.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = '9e7cd8c9-1f83-4e5d-96fb-3b1a46b5a594'
    Author            = 'WinAdvisor contributors'
    CompanyName       = 'WinAdvisor'
    Copyright         = 'Licensed under the MIT License.'
    Description       = 'Adaptive Windows 11 maintenance advisor, diagnostics toolkit and approval-gated cleanup orchestrator.'
    PowerShellVersion = '5.1'

    # Windows-only by construction: the toolkit inspects and services Windows itself.
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'Start-WinAdvisor'
        'Get-WaConfiguration'
        'Get-WaMachineProfile'
        'Get-WaAnalysis'
        'Get-WaQuestion'
        'New-WaPlan'
        'Grant-WaApproval'
        'Invoke-WaPlan'
        'Get-WaBaseline'
        'Compare-WaBaseline'
        'Export-WaReport'
        'Get-WaProvider'
        'Get-WaRollbackSession'
        'Invoke-WaRollback'
        'New-WaSession'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Windows11', 'Maintenance', 'Diagnostics', 'Cleanup', 'Advisor')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ProjectUri = 'https://github.com/winadvisor/winadvisor'
        }
    }
}
