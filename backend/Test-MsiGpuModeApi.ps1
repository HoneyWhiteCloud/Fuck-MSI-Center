# Elevated, read-only production GPU API integration test.
# No request is confirmed, so this script performs no UEFI, MSI_ACPI Set, or
# Registry write.

#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param([switch]$Json)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'MsiGpuModeApi.psd1'
$sourcePath = Join-Path $PSScriptRoot 'MsiGpuModeApi.psm1'
$bridgePath = Join-Path $PSScriptRoot 'Invoke-FuckMsiCenter.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$registryPath = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module\GeneralSetting'
$modeNames = @('Hybrid', 'Discrete', 'Integrated')

Import-Module $modulePath -Force

$beforeRegistry = Get-ItemProperty -LiteralPath $registryPath
$before = Get-MsiGpuModeStatus
if (-not $before.Success -or -not $before.CrossCheckPassed) {
    throw "Production direct Status failed: $($before.Error)"
}
if (-not $before.ServiceIndependent -or $before.Backend -ne 'WindowsFirmwareApi+DirectWmiAcpi') {
    throw 'Production Status did not select the direct service-independent backend.'
}

$plans = @(
    foreach ($target in $modeNames) {
        $plan = Get-MsiGpuModePlan -Target $target
        $targetIndex = [Array]::IndexOf($modeNames, $target)
        [byte]$current = [Convert]::ToByte($plan.CurrentUefiByte5.Substring(2), 16)
        [byte]$expected = (($current -band 0xFC) -bor $targetIndex)
        if (-not $plan.Success -or -not $plan.ServiceIndependent -or
            $plan.MsiRegistryWrites -ne 0 -or $plan.CentralServerFrames -ne 0 -or
            $plan.PlannedUefiByte5 -ne ('0x{0:X2}' -f $expected)) {
            throw "Production direct Plan failed for $target."
        }
        $plan
    }
)

$confirmationGuardPassed = $false
try {
    Request-MsiGpuModeSwitch -Target Hybrid -ConfirmRegistryAndFirmwareWrite:$false | Out-Null
}
catch {
    $confirmationGuardPassed = $_.Exception.Message -match 'explicit confirmation'
}
if (-not $confirmationGuardPassed) {
    throw 'Production Request without explicit confirmation was not blocked.'
}

$after = Get-MsiGpuModeStatus
$afterRegistry = Get-ItemProperty -LiteralPath $registryPath
$registryUnchanged = (
    [int]$beforeRegistry.GPUswitchST -eq [int]$afterRegistry.GPUswitchST -and
    [int]$beforeRegistry.GPUswitchCH -eq [int]$afterRegistry.GPUswitchCH
)
if (-not $after.Success -or $after.ModeIndex -ne $before.ModeIndex -or
    $after.UefiByte5 -ne $before.UefiByte5 -or $after.ApPending -ne $before.ApPending) {
    throw 'Read-only production test changed GPU state or final read-back was inconsistent.'
}
if (-not $registryUnchanged) {
    throw 'Read-only production test unexpectedly changed MSI GPU Registry state.'
}

$source = Get-Content -Raw -LiteralPath $sourcePath
$forbiddenImplementationTokens = @('TcpClient', '32683', 'Set-ItemProperty', 'Request-MsiGpuModeViaCentralServer')
$presentForbiddenTokens = @($forbiddenImplementationTokens | Where-Object { $source.Contains($_) })
if ($presentForbiddenTokens.Count -ne 0) {
    throw "Production module still contains service/Registry implementation tokens: $($presentForbiddenTokens -join ', ')"
}

[string]$bridgeStatusJson = (& $windowsPowerShell -NoProfile -NonInteractive `
    -ExecutionPolicy Bypass -File $bridgePath -Command Status -Json) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw "Production JSON bridge Status failed with exit code $LASTEXITCODE`: $bridgeStatusJson"
}
$bridgeStatus = $bridgeStatusJson | ConvertFrom-Json
if (-not $bridgeStatus.Success -or -not $bridgeStatus.ServiceIndependent -or
    $bridgeStatus.ModeIndex -ne $before.ModeIndex) {
    throw 'Production JSON bridge Status returned inconsistent data.'
}

[string]$bridgePlanJson = (& $windowsPowerShell -NoProfile -NonInteractive `
    -ExecutionPolicy Bypass -File $bridgePath -Command Plan -Target Hybrid -Json) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw "Production JSON bridge Plan failed with exit code $LASTEXITCODE`: $bridgePlanJson"
}
$bridgePlan = $bridgePlanJson | ConvertFrom-Json
if (-not $bridgePlan.Success -or -not $bridgePlan.ServiceIndependent -or
    $bridgePlan.Target -ne 'Hybrid' -or $bridgePlan.CentralServerFrames -ne 0) {
    throw 'Production JSON bridge Plan returned inconsistent data.'
}

$result = [pscustomobject]@{
    Success = $true
    Operation = 'ProductionGpuApiReadOnlyIntegrationTest'
    Backend = $before.Backend
    ServiceIndependent = $before.ServiceIndependent
    AppliedMode = $before.Mode
    AppliedModeIndex = $before.ModeIndex
    UefiByte5 = $before.UefiByte5
    LegacyWmiData0 = $before.LegacyWmiData0
    CrossCheckPassed = $before.CrossCheckPassed
    ApPending = $before.ApPending
    FirmwareLength = $before.FirmwareLength
    FirmwareAttributes = $before.FirmwareAttributes
    PlansValidated = @($plans | ForEach-Object { $_.Target })
    ConfirmationGuardPassed = $confirmationGuardPassed
    JsonBridgeStatusPassed = $true
    JsonBridgePlanPassed = $true
    MsiRegistryUnchanged = $registryUnchanged
    MsiRegistryWrites = 0
    CentralServerFramesSent = 0
    FirmwareWrites = 0
    SetDataCalls = 0
    ForbiddenImplementationTokens = $presentForbiddenTokens
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
}
else {
    $result | Format-List *
}
