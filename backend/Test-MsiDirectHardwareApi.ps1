# Non-destructive contract tests for the service-independent hardware backend.
# No Set_Data or firmware-variable write is invoked by this script.

#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MsiDirectHardwareApi.psd1') -Force

$hybrid = Get-MsiDirectGpuModePlan -Target Hybrid -CurrentUefiByte5 0x31 -CurrentApData1 0x00
$discrete = Get-MsiDirectGpuModePlan -Target Discrete -CurrentUefiByte5 0x32 -CurrentApData1 0x04
$integrated = Get-MsiDirectGpuModePlan -Target Integrated -CurrentUefiByte5 0x31 -CurrentApData1 0x00

if ($hybrid.PlannedUefiByte5 -ne '0x30' -or
    $discrete.PlannedUefiByte5 -ne '0x31' -or
    $integrated.PlannedUefiByte5 -ne '0x32') {
    throw 'The direct GPU plan did not preserve UEFI byte 5 bits 2-7 while replacing bits 0-1.'
}
if ($hybrid.Trigger -ne 'MSI_ACPI.Set_Data(0xD1, 0x01)' -or
    $discrete.Trigger -ne 'MSI_ACPI.Set_Data(0xD1, 0x05)') {
    throw 'The direct GPU plan did not reproduce MSI Base Module D1 payload construction.'
}
if ($integrated.Acknowledge -ne 'MSI_ACPI.Set_Data(0xBE, 0x02)' -or
    $integrated.WritesOnPlan -or -not $integrated.ServiceIndependent) {
    throw 'The direct GPU plan failed its side-effect-free service-independent contract.'
}

$confirmationGuardPassed = $false
try {
    Set-MsiDirectWebCamState -Enabled $false -ConfirmSystemChange:$false
}
catch {
    $confirmationGuardPassed = $_.Exception.Message -match 'ConfirmSystemChange'
}
if (-not $confirmationGuardPassed) {
    throw 'Direct WebCam Set without confirmation was not blocked.'
}

$gpuConfirmationGuardPassed = $false
try {
    Request-MsiDirectGpuModeSwitch -Target Discrete -ConfirmDirectFirmwareWrite:$false
}
catch {
    $gpuConfirmationGuardPassed = $_.Exception.Message -match 'ConfirmDirectFirmwareWrite'
}
if (-not $gpuConfirmationGuardPassed) {
    throw 'Direct GPU request without confirmation was not blocked.'
}

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$probe = $null
$probeError = $null
try {
    $probe = Get-MsiDirectHardwareProbe
}
catch {
    $probeError = $_.Exception.Message
    if ($isAdministrator) {
        throw
    }
}

[pscustomobject]@{
    Success = $true
    PureGpuPlansPassed = $true
    ConfirmationGuardPassed = $true
    GpuConfirmationGuardPassed = $true
    IsAdministrator = $isAdministrator
    LiveReadOnlyProbePassed = ($null -ne $probe)
    LiveReadOnlyProbeSkipped = (-not $isAdministrator -and $null -eq $probe)
    LiveReadOnlyProbeError = $probeError
    SetDataCalls = 0
    FirmwareWriteCalls = 0
}
