@{
    RootModule        = 'MsiGpuModeApi.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '0f03f306-fffe-4218-b952-241bca7a010b'
    Author            = 'Fuck-MSI-Center'
    Description       = 'Service-independent MSI GPU MUX API using Windows firmware-variable and direct MSI_ACPI calls.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-MsiGpuModePlan',
        'Get-MsiGpuModeStatus',
        'Request-MsiGpuModeSwitch'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
