# Non-destructive regression tests for the bundled GPU OC API.
# No profile save and no GPU setter is authorized by this script.

#requires -Version 5.1

[CmdletBinding()]
param([switch]$IncludeNativeProbe)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MsiGpuOcApi.psd1') -Force

$scenarioKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module\Scenario'
$userScenarioKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module\User Scenario'
$names = @(
    'OC', 'IsSupOC', 'OCrun',
    'GPU_Core_Preset', 'GPU_Core_Minimum', 'GPU_Core_Maximum',
    'GPU_VRAM_Preset', 'GPU_VRAM_Minimum', 'GPU_VRAM_Maximum',
    'High_GPU_Core', 'High_GPU_VRAM', 'User_GPU_Core', 'User_GPU_VRAM'
)

function Get-TestSnapshot {
    $scenario = Get-ItemProperty -LiteralPath $scenarioKey
    $user = Get-ItemProperty -LiteralPath $userScenarioKey
    $result = [ordered]@{}
    foreach ($name in $names) {
        $property = $scenario.PSObject.Properties[$name]
        $result[$name] = if ($null -eq $property) { $null } else { $property.Value }
    }
    $result['Mode'] = $user.Mode
    $result['Intelligent'] = $user.Intelligent
    return ($result | ConvertTo-Json -Compress)
}

$before = Get-TestSnapshot
$state = Get-MsiGpuOcState
if (-not $state.Success -or -not $state.SideEffectFree) {
    throw 'OCStatus safety invariant failed.'
}

foreach ($target in @('Current', 'ExtremePerformance', 'Balanced', 'Silent', 'SuperBattery', 'User')) {
    $plan = Get-MsiGpuOcPlan -Target $target
    if (-not $plan.Success -or -not $plan.SideEffectFree -or $plan.WritesRegistry -or $plan.WritesGpu) {
        throw "OCPlan safety invariant failed for $target."
    }
}
$driverMaximumPlan = Get-MsiGpuOcPlan -Target ExtremePerformance `
    -CoreOffsetMHz $state.Limits.CoreMaximumMHz `
    -MemoryOffsetMHz $state.Limits.MemoryMaximumMHz
if ($driverMaximumPlan.CoreOffsetMHz -ne $state.Limits.CoreMaximumMHz -or
    $driverMaximumPlan.MemoryOffsetMHz -ne $state.Limits.MemoryMaximumMHz) {
    throw 'Driver-reported maximum plan was not accepted.'
}

$savePreview = Set-MsiGpuOcProfile -Target User `
    -CoreOffsetMHz $state.Registry.UserCoreMHz `
    -MemoryOffsetMHz $state.Registry.UserMemoryMHz
if (-not $savePreview.SideEffectFree -or $savePreview.WritesRegistry) {
    throw 'Profile save preview safety invariant failed.'
}

$unconfirmedSaveRejected = $false
try {
    Set-MsiGpuOcProfile -Target User -CoreOffsetMHz $state.Registry.UserCoreMHz `
        -MemoryOffsetMHz $state.Registry.UserMemoryMHz -Save | Out-Null
}
catch { $unconfirmedSaveRejected = $true }
if (-not $unconfirmedSaveRejected) { throw 'Unconfirmed profile save was not rejected.' }

$unconfirmedApplyRejected = $false
try {
    Invoke-MsiGpuOcOffset -CoreOffsetMHz $state.Limits.CoreMinimumMHz `
        -MemoryOffsetMHz $state.Limits.MemoryMinimumMHz -Apply | Out-Null
}
catch { $unconfirmedApplyRejected = $true }
if (-not $unconfirmedApplyRejected) { throw 'Unconfirmed GPU apply was not rejected.' }

$native = $null
if ($IncludeNativeProbe) {
    $native = Get-MsiGpuOcNativeInfo
    if (-not $native.Success -or -not $native.SideEffectFree) {
        throw 'Native read-only probe failed.'
    }
}

$after = Get-TestSnapshot
if ($before -cne $after) {
    throw "Registry changed during non-destructive tests.`nBefore: $before`nAfter:  $after"
}

[pscustomobject]@{
    Success                 = $true
    RegistryUnchanged       = $true
    PlansValidated          = 6
    SavePreviewValidated    = $true
    SaveGuardValidated      = $unconfirmedSaveRejected
    ApplyGuardValidated     = $unconfirmedApplyRejected
    NativeProbeIncluded     = [bool]$IncludeNativeProbe
    NativeProbe             = $native
    DriverLimits            = $state.Limits
    DriverMaximumPlan       = $true
}
