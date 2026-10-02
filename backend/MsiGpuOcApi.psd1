@{
    RootModule        = 'MsiGpuOcApi.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = '973d80bc-16e0-4c51-8ed7-b7a01c883be8'
    Author            = 'Fuck-MSI-Center'
    Description       = 'Read-only-by-default MSI Center GPU core/VRAM offset research API with a guarded direct apply path.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-MsiGpuOcState',
        'Get-MsiGpuOcDriverLimits',
        'Get-MsiGpuOcPlan',
        'Get-MsiGpuOcNativeInfo',
        'Set-MsiGpuOcProfile',
        'Invoke-MsiGpuOcOffset'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('MSI', 'GPU', 'ReverseEngineering', 'NVAPI')
        }
    }
}
