# Fuck-MSI-Center CLI and JSON bridge for GPU, system and battery APIs.
# This script never elevates itself and never shuts down or restarts Windows.

#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'Status', 'Plan', 'Request',
        'OCStatus', 'OCPlan', 'OCProbe', 'OCSave', 'OCApply',
        'SystemStatus', 'SystemPlan', 'SystemSet',
        'BatteryStatus', 'BatteryPlan', 'BatterySet',
        'DirectProbe', 'DirectGpuPlan', 'DirectGpuRequest'
    )]
    [string]$Command,

    [string]$Target,

    [string]$Feature,

    [Nullable[int]]$Enabled,

    [switch]$ConfirmRegistryAndFirmwareWrite,

    [switch]$ConfirmSystemChange,

    [switch]$ConfirmDirectFirmwareWrite,

    [Nullable[int]]$ChargeLimitPercent,
    [switch]$ConfirmBatteryChange,

    [Nullable[int]]$CoreOffsetMHz,
    [Nullable[int]]$MemoryOffsetMHz,
    [switch]$ConfirmRegistryWrite,
    [switch]$ConfirmHardwareRisk,
    [string]$ExpectedModel,
    [string]$ExpectedGpuName,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'MsiGpuModeApi.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'MsiGpuOcApi.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'MsiSystemControlApi.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'MsiDirectHardwareApi.psd1') -Force

    $result = switch ($Command) {
        'Status' {
            Get-MsiGpuModeStatus
        }
        'Plan' {
            if ([string]::IsNullOrWhiteSpace($Target)) {
                throw '-Target is required for Plan.'
            }
            Get-MsiGpuModePlan -Target $Target
        }
        'Request' {
            if ([string]::IsNullOrWhiteSpace($Target)) {
                throw '-Target is required for Request.'
            }
            Request-MsiGpuModeSwitch -Target $Target -ConfirmRegistryAndFirmwareWrite:$ConfirmRegistryAndFirmwareWrite
        }
        'OCStatus' {
            Get-MsiGpuOcState
        }
        'OCPlan' {
            if ([string]::IsNullOrWhiteSpace($Target)) {
                throw '-Target is required for OCPlan.'
            }
            $parameters = @{ Target = $Target }
            if ($PSBoundParameters.ContainsKey('CoreOffsetMHz')) { $parameters.CoreOffsetMHz = [int]$CoreOffsetMHz }
            if ($PSBoundParameters.ContainsKey('MemoryOffsetMHz')) { $parameters.MemoryOffsetMHz = [int]$MemoryOffsetMHz }
            Get-MsiGpuOcPlan @parameters
        }
        'OCProbe' {
            Get-MsiGpuOcNativeInfo
        }
        'OCSave' {
            if ([string]::IsNullOrWhiteSpace($Target)) {
                throw '-Target is required for OCSave.'
            }
            if (-not $PSBoundParameters.ContainsKey('CoreOffsetMHz') -or -not $PSBoundParameters.ContainsKey('MemoryOffsetMHz')) {
                throw 'OCSave requires -CoreOffsetMHz and -MemoryOffsetMHz.'
            }
            Set-MsiGpuOcProfile -Target $Target -CoreOffsetMHz ([int]$CoreOffsetMHz) `
                -MemoryOffsetMHz ([int]$MemoryOffsetMHz) -Save `
                -ConfirmRegistryWrite:$ConfirmRegistryWrite `
                -ExpectedModel $ExpectedModel -ExpectedGpuName $ExpectedGpuName
        }
        'OCApply' {
            if (-not $PSBoundParameters.ContainsKey('CoreOffsetMHz') -or -not $PSBoundParameters.ContainsKey('MemoryOffsetMHz')) {
                throw 'OCApply requires -CoreOffsetMHz and -MemoryOffsetMHz.'
            }
            Invoke-MsiGpuOcOffset -CoreOffsetMHz ([int]$CoreOffsetMHz) `
                -MemoryOffsetMHz ([int]$MemoryOffsetMHz) -Apply `
                -ConfirmHardwareRisk:$ConfirmHardwareRisk `
                -ExpectedModel $ExpectedModel -ExpectedGpuName $ExpectedGpuName
        }
        'SystemStatus' {
            Get-MsiSystemControlStatus
        }
        'SystemPlan' {
            if ([string]::IsNullOrWhiteSpace($Feature)) {
                throw '-Feature is required for SystemPlan.'
            }
            if (-not $PSBoundParameters.ContainsKey('Enabled') -or [int]$Enabled -notin 0, 1) {
                throw 'SystemPlan requires -Enabled 0 or 1.'
            }
            Get-MsiSystemControlPlan -Feature $Feature -Enabled ([bool][int]$Enabled)
        }
        'SystemSet' {
            if ([string]::IsNullOrWhiteSpace($Feature)) {
                throw '-Feature is required for SystemSet.'
            }
            if (-not $PSBoundParameters.ContainsKey('Enabled') -or [int]$Enabled -notin 0, 1) {
                throw 'SystemSet requires -Enabled 0 or 1.'
            }
            Set-MsiSystemControl -Feature $Feature -Enabled ([bool][int]$Enabled) `
                -ConfirmSystemChange:$ConfirmSystemChange
        }
        'BatteryStatus' {
            Get-MsiDirectBatteryState
        }
        'BatteryPlan' {
            if (-not $PSBoundParameters.ContainsKey('ChargeLimitPercent')) {
                throw 'BatteryPlan requires -ChargeLimitPercent 60, 80, or 100.'
            }
            Get-MsiDirectBatteryPlan -ChargeLimitPercent ([int]$ChargeLimitPercent)
        }
        'BatterySet' {
            if (-not $PSBoundParameters.ContainsKey('ChargeLimitPercent')) {
                throw 'BatterySet requires -ChargeLimitPercent 60, 80, or 100.'
            }
            Set-MsiDirectBatteryLimit -ChargeLimitPercent ([int]$ChargeLimitPercent) `
                -ConfirmBatteryChange:$ConfirmBatteryChange
        }
        'DirectProbe' {
            Get-MsiDirectHardwareProbe
        }
        'DirectGpuPlan' {
            if ([string]::IsNullOrWhiteSpace($Target)) {
                throw '-Target is required for DirectGpuPlan.'
            }
            Get-MsiDirectGpuModePlan -Target $Target
        }
        'DirectGpuRequest' {
            if ([string]::IsNullOrWhiteSpace($Target)) {
                throw '-Target is required for DirectGpuRequest.'
            }
            Request-MsiDirectGpuModeSwitch -Target $Target `
                -ConfirmDirectFirmwareWrite:$ConfirmDirectFirmwareWrite
        }
    }

    if ($Json) {
        $result | ConvertTo-Json -Depth 8
    }
    else {
        $result | Format-List *
    }

    if ($null -ne $result.PSObject.Properties['Success'] -and -not [bool]$result.Success) {
        if ($null -ne $result.PSObject.Properties['ExitCode']) {
            exit [int]$result.ExitCode
        }
        exit 1
    }
    exit 0
}
catch {
    $failure = [pscustomobject]@{
        ApiVersion = '0.6.0'
        Success    = $false
        Operation  = $Command
        ExitCode   = 1
        Error      = $_.Exception.Message
    }

    if ($Json) {
        $failure | ConvertTo-Json -Depth 4
    }
    else {
        $failure | Format-List *
    }
    exit 1
}
