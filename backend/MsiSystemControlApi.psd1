@{
    RootModule        = 'MsiSystemControlApi.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = '6dc3362f-7bd9-41e7-bf6c-6005ec07f247'
    Author            = 'Fuck-MSI-Center'
    Description       = 'Allowlisted MSI system controls with a service-independent direct WMI webcam backend.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-MsiSystemControlStatus',
        'Get-MsiSystemControlPlan',
        'Set-MsiSystemControl'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('MSI', 'CentralServer', 'WMI', 'Hardware', 'ReverseEngineering')
        }
    }
}
