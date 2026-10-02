# Read-only-by-default API for the MSI Center GPU core/memory offset path.
# The only state-changing function requires -Apply, -ConfirmHardwareRisk,
# an exact model name, and an exact NVIDIA adapter name.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NvapiDriverLimits.ps1')

$script:ApiVersion = '0.3.0'
$script:BaseKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module'
$script:ScenarioKey = Join-Path $script:BaseKey 'Scenario'
$script:UserScenarioKey = Join-Path $script:BaseKey 'User Scenario'
$script:ServiceRoot = 'C:\Program Files (x86)\MSI\MSI NBFoundation Service'
$script:GpuControlPath = Join-Path $script:ServiceRoot 'gpuControl.exe'
$script:GInfPath = Join-Path $script:ServiceRoot 'GInf.dll'
$script:ProfileNames = @{
    1 = 'ExtremePerformance'
    2 = 'Balanced'
    3 = 'Silent'
    4 = 'SuperBattery'
    5 = 'User'
}

function Get-MsiPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Get-MsiGpuOcRegistryData {
    $scenario = Get-ItemProperty -LiteralPath $script:ScenarioKey
    $userScenario = Get-ItemProperty -LiteralPath $script:UserScenarioKey

    return [pscustomobject]@{
        ScenarioTrigger       = [int](Get-MsiPropertyValue $scenario 'OC' 0)
        Mode                  = [int](Get-MsiPropertyValue $userScenario 'Mode' 0)
        Intelligent           = [int](Get-MsiPropertyValue $userScenario 'Intelligent' 0)
        IsSupOC               = [int](Get-MsiPropertyValue $scenario 'IsSupOC' 0)
        OCRun                 = [int](Get-MsiPropertyValue $scenario 'OCrun' 0)
        CorePresetMHz         = [int](Get-MsiPropertyValue $scenario 'GPU_Core_Preset' 0)
        CoreMinimumMHz        = [int](Get-MsiPropertyValue $scenario 'GPU_Core_Minimum' 0)
        CoreMaximumMHz        = [int](Get-MsiPropertyValue $scenario 'GPU_Core_Maximum' 0)
        MemoryPresetMHz       = [int](Get-MsiPropertyValue $scenario 'GPU_VRAM_Preset' 0)
        MemoryMinimumMHz      = [int](Get-MsiPropertyValue $scenario 'GPU_VRAM_Minimum' 0)
        MemoryMaximumMHz      = [int](Get-MsiPropertyValue $scenario 'GPU_VRAM_Maximum' 0)
        ExtremeCoreMHz        = [int](Get-MsiPropertyValue $scenario 'High_GPU_Core' 0)
        ExtremeMemoryMHz      = [int](Get-MsiPropertyValue $scenario 'High_GPU_VRAM' 0)
        UserCoreMHz           = [int](Get-MsiPropertyValue $scenario 'User_GPU_Core' 0)
        UserMemoryMHz         = [int](Get-MsiPropertyValue $scenario 'User_GPU_VRAM' 0)
    }
}

function Get-MsiGpuOcDriverLimits {
    [CmdletBinding()]
    param()

    $registryData = Get-MsiGpuOcRegistryData
    try {
        $driver = Get-MsiNvapiPstateLimits
        if (-not $driver.InfoEditable -or -not $driver.CoreEditable -or -not $driver.MemoryEditable) {
            throw 'NVIDIA P0 graphics or memory delta is not editable.'
        }
        $coreMinimum = [Math]::Max(0, [Math]::Max($registryData.CoreMinimumMHz, $driver.CoreMinimumMHz))
        $memoryMinimum = [Math]::Max(0, [Math]::Max($registryData.MemoryMinimumMHz, $driver.MemoryMinimumMHz))
        $coreMaximum = [int]$driver.CoreMaximumMHz
        $memoryMaximum = [int]$driver.MemoryMaximumMHz
        if ($coreMaximum -lt $coreMinimum -or $memoryMaximum -lt $memoryMinimum) {
            throw 'NVIDIA driver returned an unusable P0 delta range.'
        }
        return [pscustomobject]@{
            Success                    = $true
            SideEffectFree             = $true
            Source                     = 'NVIDIA NvAPI_GPU_GetPstates20 P0 delta range'
            DriverProbeSucceeded       = $true
            DriverProbeError           = $null
            DriverGpuName              = $driver.GpuName
            CoreMinimumMHz             = [int]$coreMinimum
            CoreMaximumMHz             = $coreMaximum
            MemoryMinimumMHz           = [int]$memoryMinimum
            MemoryMaximumMHz           = $memoryMaximum
            DriverCoreMinimumMHz       = [int]$driver.CoreMinimumMHz
            DriverCoreMaximumMHz       = [int]$driver.CoreMaximumMHz
            DriverMemoryMinimumMHz     = [int]$driver.MemoryMinimumMHz
            DriverMemoryMaximumMHz     = [int]$driver.MemoryMaximumMHz
            MsiPolicyCoreMinimumMHz    = [int]$registryData.CoreMinimumMHz
            MsiPolicyCoreMaximumMHz    = [int]$registryData.CoreMaximumMHz
            MsiPolicyMemoryMinimumMHz  = [int]$registryData.MemoryMinimumMHz
            MsiPolicyMemoryMaximumMHz  = [int]$registryData.MemoryMaximumMHz
            CoreMaximumExtended        = ($coreMaximum -gt $registryData.CoreMaximumMHz)
            MemoryMaximumExtended      = ($memoryMaximum -gt $registryData.MemoryMaximumMHz)
        }
    }
    catch {
        return [pscustomobject]@{
            Success                    = $true
            SideEffectFree             = $true
            Source                     = 'MSI Center Registry fallback'
            DriverProbeSucceeded       = $false
            DriverProbeError           = $_.Exception.Message
            DriverGpuName              = $null
            CoreMinimumMHz             = [int]$registryData.CoreMinimumMHz
            CoreMaximumMHz             = [int]$registryData.CoreMaximumMHz
            MemoryMinimumMHz           = [int]$registryData.MemoryMinimumMHz
            MemoryMaximumMHz           = [int]$registryData.MemoryMaximumMHz
            DriverCoreMinimumMHz       = $null
            DriverCoreMaximumMHz       = $null
            DriverMemoryMinimumMHz     = $null
            DriverMemoryMaximumMHz     = $null
            MsiPolicyCoreMinimumMHz    = [int]$registryData.CoreMinimumMHz
            MsiPolicyCoreMaximumMHz    = [int]$registryData.CoreMaximumMHz
            MsiPolicyMemoryMinimumMHz  = [int]$registryData.MemoryMinimumMHz
            MsiPolicyMemoryMaximumMHz  = [int]$registryData.MemoryMaximumMHz
            CoreMaximumExtended        = $false
            MemoryMaximumExtended      = $false
        }
    }
}

function Resolve-MsiGpuOcProfile {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 5)][int]$Index,
        [Parameter(Mandatory = $true)][object]$RegistryData
    )

    switch ($Index) {
        1 { $core = $RegistryData.ExtremeCoreMHz; $memory = $RegistryData.ExtremeMemoryMHz }
        5 { $core = $RegistryData.UserCoreMHz; $memory = $RegistryData.UserMemoryMHz }
        default { $core = 0; $memory = 0 }
    }

    return [pscustomobject]@{
        Index           = $Index
        Name            = $script:ProfileNames[$Index]
        CoreOffsetMHz   = [int]$core
        MemoryOffsetMHz = [int]$memory
    }
}

function Assert-MsiGpuOcRange {
    param(
        [Parameter(Mandatory = $true)][int]$CoreOffsetMHz,
        [Parameter(Mandatory = $true)][int]$MemoryOffsetMHz,
        [Parameter(Mandatory = $true)][object]$Limits
    )

    if ($Limits.CoreMaximumMHz -lt $Limits.CoreMinimumMHz) {
        throw 'Effective GPU core offset range is invalid or unavailable.'
    }
    if ($Limits.MemoryMaximumMHz -lt $Limits.MemoryMinimumMHz) {
        throw 'Effective VRAM offset range is invalid or unavailable.'
    }
    if ($CoreOffsetMHz -lt $Limits.CoreMinimumMHz -or $CoreOffsetMHz -gt $Limits.CoreMaximumMHz) {
        throw "Core offset $CoreOffsetMHz MHz is outside the effective range $($Limits.CoreMinimumMHz)..$($Limits.CoreMaximumMHz) MHz."
    }
    if ($MemoryOffsetMHz -lt $Limits.MemoryMinimumMHz -or $MemoryOffsetMHz -gt $Limits.MemoryMaximumMHz) {
        throw "Memory offset $MemoryOffsetMHz MHz is outside the effective range $($Limits.MemoryMinimumMHz)..$($Limits.MemoryMaximumMHz) MHz."
    }
}

function Get-MsiGpuOcState {
    [CmdletBinding()]
    param()

    $registryData = Get-MsiGpuOcRegistryData
    $limits = Get-MsiGpuOcDriverLimits
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $videoControllers = @(Get-CimInstance -ClassName Win32_VideoController | Select-Object -ExpandProperty Name)
    $effective = if ($registryData.Mode -in 1..5) {
        Resolve-MsiGpuOcProfile -Index $registryData.Mode -RegistryData $registryData
    }
    else {
        $null
    }

    return [pscustomobject]@{
        ApiVersion       = $script:ApiVersion
        Success          = $true
        Operation        = 'Status'
        SideEffectFree   = $true
        Manufacturer     = [string]$computer.Manufacturer
        Model            = [string]$computer.Model
        VideoControllers = $videoControllers
        CurrentModeIndex = $registryData.Mode
        CurrentMode      = if ($registryData.Mode -in 1..5) { $script:ProfileNames[$registryData.Mode] } else { 'Unknown' }
        EffectivePlan    = $effective
        Registry         = $registryData
        Limits           = $limits
        GpuControlPath   = $script:GpuControlPath
        GInfPath         = $script:GInfPath
    }
}

function Get-MsiGpuOcPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Current', 'ExtremePerformance', 'Balanced', 'Silent', 'SuperBattery', 'User')]
        [string]$Target,

        [Nullable[int]]$CoreOffsetMHz,
        [Nullable[int]]$MemoryOffsetMHz
    )

    $registryData = Get-MsiGpuOcRegistryData
    $limits = Get-MsiGpuOcDriverLimits
    $index = switch ($Target) {
        'Current' { $registryData.Mode }
        'ExtremePerformance' { 1 }
        'Balanced' { 2 }
        'Silent' { 3 }
        'SuperBattery' { 4 }
        'User' { 5 }
    }
    if ($index -notin 1..5) {
        throw "Current MSI scenario index is unsupported: $index"
    }

    $profile = Resolve-MsiGpuOcProfile -Index $index -RegistryData $registryData
    if ($PSBoundParameters.ContainsKey('CoreOffsetMHz')) { $profile.CoreOffsetMHz = [int]$CoreOffsetMHz }
    if ($PSBoundParameters.ContainsKey('MemoryOffsetMHz')) { $profile.MemoryOffsetMHz = [int]$MemoryOffsetMHz }
    if ($index -in 2, 3, 4 -and ($profile.CoreOffsetMHz -ne 0 -or $profile.MemoryOffsetMHz -ne 0)) {
        throw 'MSI Center hard-codes Balanced, Silent, and Super Battery GPU offsets to 0/0.'
    }
    Assert-MsiGpuOcRange -CoreOffsetMHz $profile.CoreOffsetMHz -MemoryOffsetMHz $profile.MemoryOffsetMHz -Limits $limits

    return [pscustomobject]@{
        ApiVersion                 = $script:ApiVersion
        Success                    = $true
        Operation                  = 'Plan'
        SideEffectFree             = $true
        Target                     = $profile.Name
        ScenarioIndex              = $profile.Index
        CoreOffsetMHz              = $profile.CoreOffsetMHz
        MemoryOffsetMHz            = $profile.MemoryOffsetMHz
        AllowedCoreRangeMHz        = @($limits.CoreMinimumMHz, $limits.CoreMaximumMHz)
        AllowedMemoryRangeMHz      = @($limits.MemoryMinimumMHz, $limits.MemoryMaximumMHz)
        LimitSource                = $limits.Source
        DriverLimits               = $limits
        DirectExecutable           = $script:GpuControlPath
        DirectArguments            = @([string]$profile.CoreOffsetMHz, [string]$profile.MemoryOffsetMHz)
        OfficialTriggerKey         = $script:ScenarioKey
        OfficialTriggerValue       = "OC=$($profile.Index)"
        OfficialBroker             = 'OmApSvcBroker.exe'
        OfficialNativeLibrary      = $script:GInfPath
        PersistsScenarioValues     = $false
        WritesRegistry             = $false
        WritesGpu                  = $false
    }
}

function Initialize-MsiGpuOcInterop {
    if (([System.Management.Automation.PSTypeName]'MsiGpuOcInteropV1.Native').Type) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:GInfPath -PathType Leaf)) {
        throw "GInf.dll was not found: $($script:GInfPath)"
    }

    $escapedPath = $script:GInfPath.Replace('\', '\\')
    $source = @"
using System;
using System.Runtime.InteropServices;

namespace MsiGpuOcInteropV1
{
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct GPUInfoStruct
    {
        public Int32 pState;
        public UInt32 CoreClockMin;
        public UInt32 CoreClockMax;
        public UInt32 MemoryClockMin;
        public UInt32 MemoryClockMax;
        public UInt32 GPUOverClocks;
        public UInt32 MemoryOverClocks;
        public UInt32 GPUClock;
        public UInt32 MemoryClock;
        public UInt32 CurrentTemperature;
    }

    public static class Native
    {
        [DllImport("$escapedPath", CallingConvention = CallingConvention.Winapi)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool InitialAndGetCurrentG();

        [DllImport("$escapedPath", CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool GetGInfo(ref GPUInfoStruct info);

        [DllImport("$escapedPath", CallingConvention = CallingConvention.Winapi)]
        [return: MarshalAs(UnmanagedType.I1)]
        public static extern bool Unload();
    }
}
"@
    Add-Type -TypeDefinition $source -Language CSharp
}

function Get-MsiGpuOcNativeInfo {
    [CmdletBinding()]
    param()

    Initialize-MsiGpuOcInterop
    $initialized = [MsiGpuOcInteropV1.Native]::InitialAndGetCurrentG()
    if (-not $initialized) {
        throw 'GInf.InitialAndGetCurrentG returned false.'
    }

    $info = [MsiGpuOcInteropV1.GPUInfoStruct]::new()
    try {
        $readSucceeded = [MsiGpuOcInteropV1.Native]::GetGInfo([ref]$info)
        if (-not $readSucceeded) {
            throw 'GInf.GetGInfo returned false.'
        }
    }
    finally {
        $unloaded = [MsiGpuOcInteropV1.Native]::Unload()
    }

    return [pscustomobject]@{
        ApiVersion             = $script:ApiVersion
        Success                = $true
        Operation              = 'NativeProbe'
        SideEffectFree         = $true
        Initialized            = $initialized
        ReadSucceeded          = $readSucceeded
        Unloaded               = $unloaded
        PState                 = $info.pState
        CoreClockMinimumMHz    = $info.CoreClockMin
        CoreClockMaximumMHz    = $info.CoreClockMax
        MemoryClockMinimumMHz  = $info.MemoryClockMin
        MemoryClockMaximumMHz  = $info.MemoryClockMax
        CoreOffsetMHz          = $info.GPUOverClocks
        MemoryOffsetMHz        = $info.MemoryOverClocks
        CurrentCoreClockMHz    = $info.GPUClock
        CurrentMemoryClockMHz  = $info.MemoryClock
        CurrentTemperatureC    = $info.CurrentTemperature
    }
}

function Test-MsiSignedBinary {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required MSI binary was not found: $Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode signature is not valid for $Path (status: $($signature.Status))."
    }
    if ($null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Micro-Star International') {
        throw "Unexpected signer for $Path"
    }
    return [pscustomobject]@{
        Path       = $Path
        SHA256     = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Signer     = $signature.SignerCertificate.Subject
        FileVersion = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
    }
}

function Test-MsiGpuOcAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-MsiGpuOcHardwareIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedModel,
        [Parameter(Mandatory = $true)][string]$ExpectedGpuName
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedModel) -or [string]::IsNullOrWhiteSpace($ExpectedGpuName)) {
        throw 'Exact ExpectedModel and ExpectedGpuName guards are required.'
    }
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $gpuNames = @(Get-CimInstance -ClassName Win32_VideoController | Select-Object -ExpandProperty Name)
    if ([string]$computer.Manufacturer -notmatch 'Micro-Star International') {
        throw "Unexpected system manufacturer: $($computer.Manufacturer)"
    }
    if ([string]$computer.Model -cne $ExpectedModel) {
        throw "Model guard failed. Actual='$($computer.Model)', Expected='$ExpectedModel'."
    }
    if ($gpuNames -cnotcontains $ExpectedGpuName) {
        throw "GPU guard failed. Installed='$($gpuNames -join '; ')', Expected='$ExpectedGpuName'."
    }
    return [pscustomobject]@{
        Manufacturer = [string]$computer.Manufacturer
        Model        = [string]$computer.Model
        GpuName      = $ExpectedGpuName
    }
}

function Set-MsiGpuOcProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ExtremePerformance', 'User')]
        [string]$Target,
        [Parameter(Mandatory = $true)][int]$CoreOffsetMHz,
        [Parameter(Mandatory = $true)][int]$MemoryOffsetMHz,
        [switch]$Save,
        [switch]$ConfirmRegistryWrite,
        [string]$ExpectedModel,
        [string]$ExpectedGpuName
    )

    $registryData = Get-MsiGpuOcRegistryData
    $limits = Get-MsiGpuOcDriverLimits
    Assert-MsiGpuOcRange -CoreOffsetMHz $CoreOffsetMHz -MemoryOffsetMHz $MemoryOffsetMHz -Limits $limits
    $coreName = if ($Target -eq 'ExtremePerformance') { 'High_GPU_Core' } else { 'User_GPU_Core' }
    $memoryName = if ($Target -eq 'ExtremePerformance') { 'High_GPU_VRAM' } else { 'User_GPU_VRAM' }
    $beforeCore = if ($Target -eq 'ExtremePerformance') { $registryData.ExtremeCoreMHz } else { $registryData.UserCoreMHz }
    $beforeMemory = if ($Target -eq 'ExtremePerformance') { $registryData.ExtremeMemoryMHz } else { $registryData.UserMemoryMHz }

    $preview = [pscustomobject]@{
        ApiVersion       = $script:ApiVersion
        Success          = $true
        Operation        = 'ProfileSavePlan'
        SideEffectFree   = $true
        Target           = $Target
        CoreValueName    = $coreName
        MemoryValueName  = $memoryName
        BeforeCoreMHz    = [int]$beforeCore
        BeforeMemoryMHz  = [int]$beforeMemory
        CoreOffsetMHz    = $CoreOffsetMHz
        MemoryOffsetMHz  = $MemoryOffsetMHz
        WritesRegistry   = $false
        WritesGpu        = $false
    }
    if (-not $Save) {
        return $preview
    }
    if (-not $ConfirmRegistryWrite) {
        throw 'Saving a profile requires -ConfirmRegistryWrite. Omit -Save for a side-effect-free preview.'
    }
    if (-not (Test-MsiGpuOcAdministrator)) {
        throw 'Saving a profile requires an elevated PowerShell session.'
    }
    if ($registryData.IsSupOC -ne 1) {
        throw "MSI Center does not report GPU overclock support (IsSupOC=$($registryData.IsSupOC))."
    }
    $hardware = Assert-MsiGpuOcHardwareIdentity -ExpectedModel $ExpectedModel -ExpectedGpuName $ExpectedGpuName
    if ($beforeCore -eq $CoreOffsetMHz -and $beforeMemory -eq $MemoryOffsetMHz) {
        return [pscustomobject]@{
            ApiVersion      = $script:ApiVersion
            Success         = $true
            Operation       = 'ProfileSave'
            AlreadySaved    = $true
            SideEffectFree  = $true
            Target          = $Target
            CoreOffsetMHz   = $CoreOffsetMHz
            MemoryOffsetMHz = $MemoryOffsetMHz
            Hardware        = $hardware
            WritesRegistry  = $false
            WritesGpu       = $false
        }
    }

    try {
        Set-ItemProperty -LiteralPath $script:ScenarioKey -Name $coreName -Value $CoreOffsetMHz
        Set-ItemProperty -LiteralPath $script:ScenarioKey -Name $memoryName -Value $MemoryOffsetMHz
        $verify = Get-MsiGpuOcRegistryData
        $afterCore = if ($Target -eq 'ExtremePerformance') { $verify.ExtremeCoreMHz } else { $verify.UserCoreMHz }
        $afterMemory = if ($Target -eq 'ExtremePerformance') { $verify.ExtremeMemoryMHz } else { $verify.UserMemoryMHz }
        if ($afterCore -ne $CoreOffsetMHz -or $afterMemory -ne $MemoryOffsetMHz) {
            throw 'Registry read-back did not match both requested profile values.'
        }
    }
    catch {
        try {
            Set-ItemProperty -LiteralPath $script:ScenarioKey -Name $coreName -Value ([int]$beforeCore)
            Set-ItemProperty -LiteralPath $script:ScenarioKey -Name $memoryName -Value ([int]$beforeMemory)
        }
        catch {
            throw 'Profile save failed and rollback also failed. Inspect the MSI Scenario registry values before continuing.'
        }
        throw
    }

    return [pscustomobject]@{
        ApiVersion       = $script:ApiVersion
        Success          = $true
        Operation        = 'ProfileSave'
        AlreadySaved     = $false
        SideEffectFree   = $false
        Target           = $Target
        BeforeCoreMHz    = [int]$beforeCore
        BeforeMemoryMHz  = [int]$beforeMemory
        CoreOffsetMHz    = $CoreOffsetMHz
        MemoryOffsetMHz  = $MemoryOffsetMHz
        Hardware         = $hardware
        WritesRegistry   = $true
        WritesGpu        = $false
    }
}

function Invoke-MsiGpuOcOffset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$CoreOffsetMHz,
        [Parameter(Mandatory = $true)][int]$MemoryOffsetMHz,
        [switch]$Apply,
        [switch]$ConfirmHardwareRisk,
        [string]$ExpectedModel,
        [string]$ExpectedGpuName
    )

    $registryData = Get-MsiGpuOcRegistryData
    $limits = Get-MsiGpuOcDriverLimits
    Assert-MsiGpuOcRange -CoreOffsetMHz $CoreOffsetMHz -MemoryOffsetMHz $MemoryOffsetMHz -Limits $limits
    $preview = [pscustomobject]@{
        ApiVersion             = $script:ApiVersion
        Operation              = 'DirectOffsetPlan'
        SideEffectFree         = $true
        CoreOffsetMHz          = $CoreOffsetMHz
        MemoryOffsetMHz        = $MemoryOffsetMHz
        Executable             = $script:GpuControlPath
        Arguments              = @([string]$CoreOffsetMHz, [string]$MemoryOffsetMHz)
        PersistsScenarioValues = $false
        WritesRegistry         = $false
        WritesGpu              = $false
    }
    if (-not $Apply) {
        return $preview
    }
    if (-not $ConfirmHardwareRisk) {
        throw 'Applying offsets requires -ConfirmHardwareRisk. Omit -Apply for a side-effect-free preview.'
    }
    if (-not (Test-MsiGpuOcAdministrator)) {
        throw 'Applying offsets requires an elevated PowerShell session.'
    }
    if ($registryData.IsSupOC -ne 1) {
        throw "MSI Center does not report GPU overclock support (IsSupOC=$($registryData.IsSupOC))."
    }

    $hardware = Assert-MsiGpuOcHardwareIdentity -ExpectedModel $ExpectedModel -ExpectedGpuName $ExpectedGpuName

    $gpuControlTrust = Test-MsiSignedBinary -Path $script:GpuControlPath
    $gInfTrust = Test-MsiSignedBinary -Path $script:GInfPath
    $before = Get-MsiGpuOcNativeInfo
    if ([int64]$before.CoreOffsetMHz -eq $CoreOffsetMHz -and [int64]$before.MemoryOffsetMHz -eq $MemoryOffsetMHz) {
        return [pscustomobject]@{
            ApiVersion             = $script:ApiVersion
            Operation              = 'DirectOffsetApply'
            Success                = $true
            AlreadyApplied         = $true
            SideEffectFree         = $true
            CoreOffsetMHz          = $CoreOffsetMHz
            MemoryOffsetMHz        = $MemoryOffsetMHz
            Before                 = $before
            After                  = $before
            ProcessExitCode        = $null
            GpuControlTrust        = $gpuControlTrust
            GInfTrust              = $gInfTrust
            Hardware               = $hardware
            PersistsScenarioValues = $false
            WritesRegistry         = $false
            WritesGpu              = $false
        }
    }
    $process = Start-Process -FilePath $script:GpuControlPath `
        -ArgumentList @([string]$CoreOffsetMHz, [string]$MemoryOffsetMHz) `
        -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "gpuControl.exe returned exit code $($process.ExitCode)."
    }
    $after = Get-MsiGpuOcNativeInfo
    $verified = ([int64]$after.CoreOffsetMHz -eq $CoreOffsetMHz -and [int64]$after.MemoryOffsetMHz -eq $MemoryOffsetMHz)

    return [pscustomobject]@{
        ApiVersion             = $script:ApiVersion
        Operation              = 'DirectOffsetApply'
        Success                = $verified
        AlreadyApplied         = $false
        SideEffectFree         = $false
        CoreOffsetMHz          = $CoreOffsetMHz
        MemoryOffsetMHz        = $MemoryOffsetMHz
        Before                 = $before
        After                  = $after
        ProcessExitCode        = $process.ExitCode
        GpuControlTrust        = $gpuControlTrust
        GInfTrust              = $gInfTrust
        Hardware               = $hardware
        PersistsScenarioValues = $false
        WritesRegistry         = $false
        WritesGpu              = $true
    }
}

Export-ModuleMember -Function Get-MsiGpuOcState, Get-MsiGpuOcDriverLimits, Get-MsiGpuOcPlan, Get-MsiGpuOcNativeInfo, Set-MsiGpuOcProfile, Invoke-MsiGpuOcOffset
