# Non-destructive integration test for the allowlisted MSI system-control API.
# This script sends only IsSupport/Get commands. It never sends Set.

#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$generalSettingKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module\GeneralSetting'

function Get-RelevantRegistrySnapshot {
    $item = Get-ItemProperty -LiteralPath $generalSettingKey
    return [pscustomobject]@{
        WinFn  = [int]$item.WinFn
        WinKey = [int]$item.WinKey
        ONEMSI = [int]$item.ONEMSI
    }
}

Import-Module (Join-Path $PSScriptRoot 'MsiSystemControlApi.psd1') -Force

$beforeRegistry = Get-RelevantRegistrySnapshot
$beforeStatus = Get-MsiSystemControlStatus
if (-not $beforeStatus.Success) {
    throw 'SystemStatus did not succeed.'
}
if ($null -eq $beforeStatus.PSObject.Properties['VersionMatchesValidatedStack'] -or
    $null -eq $beforeStatus.PSObject.Properties['CompatibilityWarnings']) {
    throw 'SystemStatus is missing version-compatibility metadata.'
}
if (-not $beforeStatus.VersionMatchesValidatedStack -and
    @($beforeStatus.CompatibilityWarnings).Count -eq 0) {
    throw 'A version mismatch must include at least one compatibility warning.'
}

foreach ($feature in 'WebCam', 'WinKey', 'SwitchFnWin') {
    $state = $beforeStatus.Controls.$feature
    if (-not $state.Supported -or $state.Enabled -isnot [bool]) {
        throw "$feature was expected to be supported with a Boolean state on this validated machine."
    }
    $plan = Get-MsiSystemControlPlan -Feature $feature -Enabled (-not [bool]$state.Enabled)
    $commandIsExpected = if ($feature -eq 'WebCam') {
        $plan.Backend -eq 'DirectWmiAcpi' -and
        $plan.ServiceIndependent -eq $true -and
        $plan.Command -match '^MSI_ACPI\.Set_Data\(0x2E,'
    }
    else {
        $plan.Command -match "^Set;$feature;[01]$"
    }
    if (-not $plan.Success -or $plan.WritesOnPlan -or -not $commandIsExpected) {
        throw "$feature plan failed its non-destructive contract."
    }
}

$guardBlocked = $false
try {
    Set-MsiSystemControl -Feature WebCam `
        -Enabled (-not [bool]$beforeStatus.Controls.WebCam.Enabled) `
        -ConfirmSystemChange:$false
}
catch {
    $guardBlocked = $_.Exception.Message -match 'ConfirmSystemChange'
}
if (-not $guardBlocked) {
    throw 'SystemSet without -ConfirmSystemChange was not blocked.'
}

$afterStatus = Get-MsiSystemControlStatus
$afterRegistry = Get-RelevantRegistrySnapshot

foreach ($name in 'WinFn', 'WinKey', 'ONEMSI') {
    if ($beforeRegistry.$name -ne $afterRegistry.$name) {
        throw "Registry changed during the read-only test: $name"
    }
}
foreach ($feature in 'WebCam', 'WinKey', 'SwitchFnWin') {
    if ($beforeStatus.Controls.$feature.Enabled -ne $afterStatus.Controls.$feature.Enabled) {
        throw "Feature state changed during the read-only test: $feature"
    }
}

[pscustomobject]@{
    Success                    = $true
    StatusAndPlansPassed       = $true
    ConfirmationGuardPassed   = $true
    RegistryUnchanged         = $true
    FeatureStatesUnchanged    = $true
    SetCommandsSent           = 0
    Controls                  = $afterStatus.Controls
}
