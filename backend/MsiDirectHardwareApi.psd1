@{
    RootModule        = 'MsiDirectHardwareApi.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'bc0b1053-e46b-4928-ae90-af8a1094bc5a'
    Author            = 'Fuck-MSI-Center'
    Description       = 'Direct Windows firmware-variable and MSI_ACPI WMI primitives that do not depend on MSI Center services.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-MsiDirectBatteryState',
        'Get-MsiDirectBatteryPlan',
        'Set-MsiDirectBatteryLimit',
        'Get-MsiDirectWebCamState',
        'Get-MsiDirectWebCamPlan',
        'Set-MsiDirectWebCamState',
        'Get-MsiDirectHardwareProbe',
        'Get-MsiDirectGpuModePlan',
        'Request-MsiDirectGpuModeSwitch'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('MSI', 'WMI', 'UEFI', 'Hardware', 'ReverseEngineering')
        }
    }
}
