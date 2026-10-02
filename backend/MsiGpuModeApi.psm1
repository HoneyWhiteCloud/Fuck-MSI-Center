# Stable production API for service-independent MSI GPU MUX control.
#
# The implementation reads and stages MsiDCVarData through the Windows firmware
# environment API, then uses root/WMI:MSI_ACPI directly for D1/AP/BE.  It does
# not load MSI assemblies, write MSI Registry values, or connect to
# MSI.CentralServer / OmApSvcBroker.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ApiVersion = '0.2.0'
$script:ModeNames = @('Hybrid', 'Discrete', 'Integrated')
$script:DirectModule = Join-Path $PSScriptRoot 'MsiDirectHardwareApi.psd1'

Import-Module $script:DirectModule -Force

function ConvertFrom-MsiHexResponse {
    param(
        [Parameter(Mandatory = $true)][string]$Response,
        [Parameter(Mandatory = $true)][int]$MinimumLength
    )

    [string[]]$tokens = @($Response -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -lt $MinimumLength) {
        throw "MSI_ACPI response is too short: $Response"
    }
    [byte[]]$bytes = @($tokens | ForEach-Object {
        if ($_ -notmatch '^[0-9A-Fa-f]{2}$') {
            throw "MSI_ACPI response contains an invalid byte '$_': $Response"
        }
        [Convert]::ToByte($_, 16)
    })
    return $bytes
}

function Get-MsiGpuModeStatus {
    [CmdletBinding()]
    param()

    $probe = Get-MsiDirectHardwareProbe
    if (-not $probe.Success -or -not $probe.FirmwareReadAvailable -or $null -eq $probe.Gpu) {
        $message = if ($probe.FirmwareReadError) { $probe.FirmwareReadError } else { 'Direct UEFI GPU state is unavailable.' }
        throw $message
    }

    [byte[]]$device = ConvertFrom-MsiHexResponse -Response ([string]$probe.GetDeviceResponse) -MinimumLength 2
    [byte[]]$ap = ConvertFrom-MsiHexResponse -Response ([string]$probe.GetApResponse) -MinimumLength 3
    $legacyDiscrete = (($device[1] -band 0x40) -ne 0)
    $mode = [string]$probe.Gpu.AppliedMode
    $modeIndex = [int]$probe.Gpu.AppliedModeIndex
    $stagedIndex = [int]$probe.Gpu.StagedTargetIndex
    $crossCheckPassed = (($mode -eq 'Discrete' -and $legacyDiscrete) -or
        ($mode -in @('Hybrid', 'Integrated') -and -not $legacyDiscrete))
    $layoutValid = ($modeIndex -in @(0, 1, 2) -and $stagedIndex -in @(0, 1, 2) -and
        [int]$probe.Gpu.FirmwareLength -eq 20 -and
        [bool]$probe.Gpu.AttributesMatchMsiWriter)
    $statusValid = ($crossCheckPassed -and $layoutValid)

    return [pscustomobject]@{
        ApiVersion              = $script:ApiVersion
        Success                 = [bool]$statusValid
        Operation               = 'Status'
        ExitCode                = if ($statusValid) { 0 } else { 1 }
        Mode                    = $mode
        ModeIndex               = $modeIndex
        StagedTarget            = [string]$probe.Gpu.StagedTarget
        StagedTargetIndex       = $stagedIndex
        IsPendingTarget         = ([bool]$probe.ApPending -or
            [int]$probe.Gpu.StagedTargetIndex -ne $modeIndex)
        NewSwitchSupport        = [bool]$probe.Gpu.NewSwitchSupported
        IntegratedSupport       = [bool]$probe.Gpu.IntegratedSupported
        DiscreteSupport         = [bool]$probe.Gpu.DiscreteSupported
        LegacyWmiData0          = ('0x{0:X2}' -f $device[1])
        CrossCheckPassed        = [bool]$crossCheckPassed
        FirmwareLayoutValid     = [bool]$layoutValid
        ApPending               = [bool]$probe.ApPending
        ApData1                 = [byte]$ap[2]
        GetApResponse           = [string]$probe.GetApResponse
        UefiByte5               = [string]$probe.Gpu.UefiByte5
        FirmwareLength          = [int]$probe.Gpu.FirmwareLength
        FirmwareAttributes      = [string]$probe.Gpu.FirmwareAttributes
        AttributesMatchMsiWriter = [bool]$probe.Gpu.AttributesMatchMsiWriter
        Backend                 = 'WindowsFirmwareApi+DirectWmiAcpi'
        ServiceIndependent      = $true
        WritesRegistry          = $false
        CentralServerFramesSent = 0
        RequiresAdministrator   = $true
        RawOutput               = ($probe | ConvertTo-Json -Depth 8 -Compress)
        Error                   = if ($statusValid) {
            $null
        }
        elseif (-not $layoutValid) {
            'UEFI GPU state has an unexpected mode, length, or attributes layout.'
        }
        else {
            "UEFI applied mode $mode does not agree with Get_Device(1).Data[0].bit6."
        }
    }
}

function Get-MsiGpuModePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Hybrid', 'Discrete', 'Integrated')]
        [string]$Target
    )

    $status = Get-MsiGpuModeStatus
    if (-not $status.Success) {
        throw $status.Error
    }
    if ($status.IsPendingTarget) {
        throw 'A GPU MUX request is already staged or AP pending; refusing to create a new request plan.'
    }
    if (-not $status.NewSwitchSupport) {
        throw 'UEFI reports that the new GPU switch mechanism is unsupported.'
    }
    if ($Target -eq 'Integrated' -and -not $status.IntegratedSupport) {
        throw 'UEFI reports that Integrated mode is unsupported.'
    }
    if ($Target -eq 'Discrete' -and -not $status.DiscreteSupport) {
        throw 'UEFI reports that Discrete mode is unsupported.'
    }

    [byte]$uefiByte5 = [Convert]::ToByte(([string]$status.UefiByte5).Substring(2), 16)
    $direct = Get-MsiDirectGpuModePlan -Target $Target `
        -CurrentUefiByte5 $uefiByte5 -CurrentApData1 ([byte]$status.ApData1)

    return [pscustomobject]@{
        ApiVersion                 = $script:ApiVersion
        Success                    = $true
        Operation                  = 'Plan'
        Target                     = $Target
        TargetIndex                = [int]$direct.TargetIndex
        CurrentMode                = [string]$status.Mode
        CurrentModeIndex           = [int]$status.ModeIndex
        AlreadyApplied             = ([string]$status.Mode -eq $Target)
        Backend                    = [string]$direct.Backend
        ServiceIndependent         = $true
        RegistryValue              = 'No MSI Registry write (0 writes)'
        FirmwareVariable           = [string]$direct.FirmwareVariable
        CurrentUefiByte5            = [string]$direct.CurrentUefiByte5
        PlannedUefiByte5            = [string]$direct.PlannedUefiByte5
        UefiMutation               = [string]$direct.UefiMutation
        FirmwareAttributes         = [string]$direct.FirmwareAttributes
        SwitchCommand              = [string]$direct.Trigger
        SwitchFrameHex             = $null
        AcceptanceCheck            = [string]$direct.AcceptanceCheck
        AcknowledgeCommand         = [string]$direct.Acknowledge
        AcknowledgeFrameHex        = $null
        CentralServerPort          = $null
        CentralServerDestinationId = $null
        CentralServerFrames        = 0
        MsiRegistryWrites          = 0
        DelayMilliseconds          = [int]$direct.DelayMilliseconds
        RequiresAdministrator      = $true
        RequiresManualPowerCycle   = $true
        AutomaticShutdown          = $false
        AutomaticRetry             = $false
        WritesOnPlan               = $false
        SideEffects                = @(
            'MsiDCVarData byte 5 bits 0-1 are staged with one Windows firmware-variable write.';
            'MSI_ACPI.Set_Data(0xD1) starts the firmware request and Get_AP(0).Data[1].bit1 confirms acceptance.';
            'MSI_ACPI.Set_Data(0xBE, 0x02) acknowledges the accepted request.';
            'The new MUX mode is not considered applied until a complete shutdown/startup and fresh read-back.'
        )
    }
}

function Request-MsiGpuModeSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Hybrid', 'Discrete', 'Integrated')]
        [string]$Target,

        # The legacy public parameter name is retained for GUI/API compatibility.
        # The implementation writes no MSI Registry value and calls no MSI service.
        [Parameter(Mandatory = $true)]
        [switch]$ConfirmRegistryAndFirmwareWrite
    )

    if (-not $ConfirmRegistryAndFirmwareWrite) {
        throw 'Request-MsiGpuModeSwitch requires explicit confirmation. Use Get-MsiGpuModePlan for a side-effect-free preview.'
    }

    $request = Request-MsiDirectGpuModeSwitch -Target $Target -ConfirmDirectFirmwareWrite
    $previousIndex = [Array]::IndexOf($script:ModeNames, [string]$request.PreviousMode)
    $exitCode = if ($request.Success) { 0 } else { 1 }

    return [pscustomobject]@{
        ApiVersion               = $script:ApiVersion
        Success                  = [bool]$request.Success
        Operation                = 'Request'
        ExitCode                 = $exitCode
        Target                   = $Target
        TargetIndex              = [int]$request.TargetIndex
        PreviousMode             = [string]$request.PreviousMode
        PreviousModeIndex        = $previousIndex
        AppliedMode              = [string]$request.PreviousMode
        AppliedModeIndex         = $previousIndex
        StagedTargetIndex        = if ($request.Success -and -not $request.AlreadyApplied) { [int]$request.TargetIndex } else { $previousIndex }
        RequestAccepted          = [bool]$request.RequestAccepted
        AlreadyApplied           = [bool]$request.AlreadyApplied
        ManualPowerCycleNeeded   = [bool]$request.ManualPowerCycleNeeded
        AutomaticShutdown        = $false
        AutomaticRetry           = $false
        Backend                  = 'WindowsFirmwareApi+DirectWmiAcpi'
        ServiceIndependent       = $true
        FirmwareWriteSent        = [bool]$request.FirmwareWriteSent
        D1WriteSent              = [bool]$request.D1WriteSent
        BEWriteSent              = [bool]$request.BEWriteSent
        MsiRegistryWrites        = 0
        CentralServerFramesSent  = 0
        Stage                    = [string]$request.Stage
        Error                    = if ($request.Success) { $null } else { [string]$request.Error }
        RawOutput                = ($request | ConvertTo-Json -Depth 8 -Compress)
    }
}

Export-ModuleMember -Function Get-MsiGpuModePlan, Get-MsiGpuModeStatus, Request-MsiGpuModeSwitch
