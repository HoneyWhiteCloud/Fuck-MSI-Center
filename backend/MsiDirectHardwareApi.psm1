# Direct MSI firmware/WMI primitives recovered from MSI Center.
#
# This module does not load MSI assemblies and does not connect to
# MSI.CentralServer or OmApSvcBroker.  Firmware-variable reads use the public
# Windows API; MSI ACPI calls use root/WMI:MSI_ACPI directly.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ApiVersion = '0.4.0'
$script:ExpectedManufacturerPattern = 'Micro-Star|MSI'
$script:FullFeatureModels = @('Sword 16 HX B14VGKG')
# MSI publishes one byte-identical E15P2IMS.110 image for these three Sword 16
# HX GPU SKUs.  Only the GPU MUX primitive is allowed across that horizontal
# firmware family; webcam, battery and other EC-facing controls remain locked
# to the live-validated B14VGKG model.
$script:GpuModeModels = @(
    'Sword 16 HX B14VEKG',
    'Sword 16 HX B14VFKG',
    'Sword 16 HX B14VGKG'
)
$script:BiosKey = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
$script:WmiNamespace = '\\.\root\WMI'
$script:WmiInstanceName = 'ACPI\PNP0C14\0_0'
# Keep the legacy mutex identity so older releases share the same hardware lock.
$script:AcpiMutexName = 'Local\MsiGpuModeGui-MSI-ACPI'
$script:FirmwareVariableName = 'MsiDCVarData'
$script:FirmwareVariableGuid = '{DD96BAAF-145E-4F56-B1CF-193256298E99}'
$script:FirmwareVariableAttributes = 0x00000007
$script:ModeNames = @('Hybrid', 'Discrete', 'Integrated')

function Test-MsiDirectAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-MsiDirectHardwareIdentity {
    param(
        [ValidateSet('Full', 'GpuMode')]
        [string]$Capability = 'Full'
    )

    $bios = Get-ItemProperty -LiteralPath $script:BiosKey
    $manufacturer = [string]$bios.SystemManufacturer
    $model = [string]$bios.SystemProductName
    $allowedModels = if ($Capability -eq 'GpuMode') {
        $script:GpuModeModels
    }
    else {
        $script:FullFeatureModels
    }
    if ($manufacturer -notmatch $script:ExpectedManufacturerPattern -or $model -notin $allowedModels) {
        throw "Direct MSI $Capability semantics are not allowed for this hardware: manufacturer=$manufacturer, model=$model; allowed=$($allowedModels -join ', ')"
    }
    $accessTier = if ($model -in $script:FullFeatureModels) { 'Full' } else { 'GpuModeOnly' }
    return [pscustomobject]@{
        Manufacturer = $manufacturer
        Model = $model
        FirmwareFamily = 'E15P2'
        AccessTier = $accessTier
        HorizontalCompatibility = ($accessTier -eq 'GpuModeOnly')
        AllowedCapabilities = if ($accessTier -eq 'Full') {
            @('GpuMode', 'GpuOc', 'WebCam', 'Battery', 'SystemControls')
        }
        else {
            @('GpuMode', 'GpuOc')
        }
    }
}

function Enter-MsiDirectAcpiMutex {
    $mutex = [Threading.Mutex]::new($false, $script:AcpiMutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(10000)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'Timed out waiting for exclusive access to the MSI_ACPI interface.'
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-MsiDirectAcpiMutex {
    param([Parameter(Mandatory = $true)][Threading.Mutex]$Mutex)

    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}

function Format-MsiDirectBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [int]$Maximum = 7
    )

    $count = [Math]::Min($Maximum, $Bytes.Length)
    if ($count -eq 0) {
        return ''
    }
    return (($Bytes[0..($count - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
}

function New-MsiDirectAcpiContext {
    Add-Type -AssemblyName System.Management
    $scope = [System.Management.ManagementScope]::new($script:WmiNamespace)
    $scope.Connect()
    $searcher = [System.Management.ManagementObjectSearcher]::new(
        $scope,
        [System.Management.ObjectQuery]::new('SELECT * FROM MSI_ACPI')
    )
    $instances = @($searcher.Get())
    $target = $instances |
        Where-Object { [string]$_.Properties['InstanceName'].Value -eq $script:WmiInstanceName } |
        Select-Object -First 1
    if ($null -eq $target) {
        $names = @($instances | ForEach-Object { [string]$_.Properties['InstanceName'].Value })
        throw ('Expected MSI_ACPI instance was not found. Returned: ' + ($names -join ', '))
    }
    $packageClass = [System.Management.ManagementClass]::new(
        $scope,
        [System.Management.ManagementPath]::new('Package_32'),
        $null
    )
    return [pscustomobject]@{
        Scope = $scope
        Target = $target
        PackageClass = $packageClass
        InstanceName = $script:WmiInstanceName
    }
}

function Invoke-MsiDirectAcpiMethod {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][byte[]]$Request
    )

    if ($Request.Length -ne 32) {
        throw "$Method request must contain exactly 32 bytes."
    }
    $package = $Context.PackageClass.CreateInstance()
    $package.SetPropertyValue('Bytes', $Request)
    $inParams = $Context.Target.GetMethodParameters($Method)
    $inParams.SetPropertyValue('Data', $package)
    $outParams = $Context.Target.InvokeMethod($Method, $inParams, $null)
    if ($null -eq $outParams -or $null -eq $outParams.Properties['Data'].Value) {
        throw "$Method returned no embedded Data package."
    }
    $outPackage = [System.Management.ManagementBaseObject]$outParams.Properties['Data'].Value
    [byte[]]$response = $outPackage.Properties['Bytes'].Value
    if ($null -eq $response -or $response.Length -lt 1) {
        throw "$Method returned an invalid response byte array."
    }
    $returnValue = $null
    $returnProperty = $outParams.Properties |
        Where-Object { $_.Name -eq 'ReturnValue' } |
        Select-Object -First 1
    if ($null -ne $returnProperty) {
        $returnValue = $returnProperty.Value
    }
    return [pscustomobject]@{
        Method = $Method
        Request = $Request
        Response = $response
        Flag = [byte]$response[0]
        ReturnValue = $returnValue
        ResponseHex = Format-MsiDirectBytes -Bytes $response
    }
}

function Invoke-MsiDirectAcpiGet {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('Get_Device', 'Get_AP', 'Get_Data')][string]$Method,
        [Parameter(Mandatory = $true)][byte]$Selector
    )

    [byte[]]$request = [byte[]]::new(32)
    $request[0] = $Selector
    return Invoke-MsiDirectAcpiMethod -Context $Context -Method $Method -Request $request
}

function Invoke-MsiDirectSetData {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][byte]$Address,
        [Parameter(Mandatory = $true)][byte]$Value
    )

    [byte[]]$request = [byte[]]::new(32)
    $request[0] = $Address
    $request[1] = $Value
    return Invoke-MsiDirectAcpiMethod -Context $Context -Method 'Set_Data' -Request $request
}

function Get-MsiDirectWebCamStateInternal {
    param([Parameter(Mandatory = $true)]$Context)

    $result = Invoke-MsiDirectAcpiGet -Context $Context -Method Get_Device -Selector 0x01
    if ($result.Flag -eq 0 -or $result.Response.Length -lt 3) {
        throw "Get_Device(1) returned an invalid webcam state: $($result.ResponseHex)"
    }
    [byte]$data0 = $result.Response[1]
    [byte]$data1 = $result.Response[2]
    return [pscustomobject]@{
        Feature = 'WebCam'
        DisplayName = 'Webcam hardware switch'
        Supported = (($data1 -band 0x02) -ne 0)
        Enabled = (($data0 -band 0x02) -ne 0)
        Data0 = $data0
        Data1 = $data1
        RawResponse = $result.ResponseHex
        Backend = 'DirectWmiAcpi'
        ServiceIndependent = $true
        ReadMethod = 'MSI_ACPI.Get_Device(0x01)'
        WriteMethod = 'MSI_ACPI.Set_Data(0x2E, read-modify-write Data[0].bit1)'
    }
}

function Get-MsiDirectWebCamState {
    [CmdletBinding()]
    param()

    $identity = Assert-MsiDirectHardwareIdentity
    $mutex = Enter-MsiDirectAcpiMutex
    try {
        $context = New-MsiDirectAcpiContext
        $state = Get-MsiDirectWebCamStateInternal -Context $context
        $state | Add-Member -NotePropertyName Manufacturer -NotePropertyValue $identity.Manufacturer
        $state | Add-Member -NotePropertyName Model -NotePropertyValue $identity.Model
        return $state
    }
    finally {
        Exit-MsiDirectAcpiMutex -Mutex $mutex
    }
}

function Get-MsiDirectWebCamPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    $state = Get-MsiDirectWebCamState
    if (-not $state.Supported) {
        throw 'The webcam hardware bit is not supported by this MSI firmware.'
    }
    [byte]$payload = if ($Enabled) {
        [byte]($state.Data0 -bor 0x02)
    }
    else {
        [byte]($state.Data0 -band 0xFD)
    }
    return [pscustomobject]@{
        ApiVersion = $script:ApiVersion
        Success = $true
        Operation = 'DirectWebCamPlan'
        Feature = 'WebCam'
        CurrentEnabled = [bool]$state.Enabled
        TargetEnabled = $Enabled
        AlreadyApplied = ([bool]$state.Enabled -eq $Enabled)
        Backend = 'DirectWmiAcpi'
        ServiceIndependent = $true
        ReadMethod = 'MSI_ACPI.Get_Device(0x01)'
        WriteMethod = ('MSI_ACPI.Set_Data(0x2E, 0x{0:X2})' -f $payload)
        Address = '0x2E'
        Payload = ('0x{0:X2}' -f $payload)
        RequiresAdministrator = $true
        RequiresConfirmation = $true
        AutomaticRetry = $false
        WritesOnPlan = $false
    }
}

function Set-MsiDirectWebCamState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][switch]$ConfirmSystemChange
    )

    if (-not $ConfirmSystemChange) {
        throw 'Set-MsiDirectWebCamState requires -ConfirmSystemChange.'
    }
    if (-not (Test-MsiDirectAdministrator)) {
        throw 'Administrator privileges are required for MSI_ACPI writes.'
    }
    $null = Assert-MsiDirectHardwareIdentity
    $mutex = Enter-MsiDirectAcpiMutex
    try {
        $context = New-MsiDirectAcpiContext
        $before = Get-MsiDirectWebCamStateInternal -Context $context
        if (-not $before.Supported) {
            throw 'The webcam hardware bit is not supported by this MSI firmware.'
        }
        if ([bool]$before.Enabled -eq $Enabled) {
            return [pscustomobject]@{
                ApiVersion = $script:ApiVersion
                Success = $true
                Operation = 'DirectWebCamSet'
                Feature = 'WebCam'
                PreviousEnabled = [bool]$before.Enabled
                Enabled = [bool]$before.Enabled
                AlreadyApplied = $true
                RequestSent = $false
                Verified = $true
                Backend = 'DirectWmiAcpi'
                ServiceIndependent = $true
                AutomaticRetry = $false
            }
        }
        [byte]$payload = if ($Enabled) {
            [byte]($before.Data0 -bor 0x02)
        }
        else {
            [byte]($before.Data0 -band 0xFD)
        }
        $write = Invoke-MsiDirectSetData -Context $context -Address 0x2E -Value $payload
        if ($write.Flag -eq 0) {
            throw "Set_Data(0x2E) was rejected. No retry was attempted. Response=$($write.ResponseHex)"
        }
        $after = Get-MsiDirectWebCamStateInternal -Context $context
        if (-not $after.Supported -or [bool]$after.Enabled -ne $Enabled) {
            throw 'Set_Data(0x2E) returned success but Get_Device(1) read-back did not match. No retry was attempted.'
        }
        return [pscustomobject]@{
            ApiVersion = $script:ApiVersion
            Success = $true
            Operation = 'DirectWebCamSet'
            Feature = 'WebCam'
            PreviousEnabled = [bool]$before.Enabled
            Enabled = [bool]$after.Enabled
            AlreadyApplied = $false
            RequestSent = $true
            Verified = $true
            Backend = 'DirectWmiAcpi'
            ServiceIndependent = $true
            WriteMethod = ('MSI_ACPI.Set_Data(0x2E, 0x{0:X2})' -f $payload)
            WriteResponse = $write.ResponseHex
            ReadBackResponse = $after.RawResponse
            AutomaticRetry = $false
        }
    }
    finally {
        Exit-MsiDirectAcpiMutex -Mutex $mutex
    }
}

function Get-MsiBatteryPolicyInfo {
    # Optional information only. Missing MSI Center preferences do not block direct ACPI.
    $preferences = [ordered]@{}
    foreach ($entry in @(
        @{ Name = 'CurrentUserMode'; Path = 'HKCU:\Software\Wow6432Node\MSI\MSI Center\NoteBook' },
        @{ Name = 'MachineMode'; Path = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\System Diagnosis' }
    )) {
        $value = try {
            Get-ItemPropertyValue -LiteralPath $entry.Path -Name BatteryMode -ErrorAction Stop
        } catch { $null }
        $preferences[$entry.Name] = $value
    }
    $aiEnabled = ($preferences.CurrentUserMode -eq 3 -or $preferences.MachineMode -eq 3)
    return [pscustomobject]@{
        CurrentUserMode = $preferences.CurrentUserMode
        MachineMode = $preferences.MachineMode
        AIChargerEnabled = [bool]$aiEnabled
        Warning = if ($aiEnabled) {
            'MSI AI Charger is enabled and may overwrite this direct charge limit. Select a manual mode in MSI Center to stop its automatic policy.'
        } else {
            'MSI Center may reapply its saved Battery Master mode when opened. This operation changes the hardware limit, not MSI Center preferences.'
        }
    }
}

function Get-MsiDirectBatteryStateInternal {
    param([Parameter(Mandatory = $true)]$Context)

    $read = Invoke-MsiDirectAcpiGet -Context $Context -Method Get_Data -Selector 0xD7
    if ($read.Flag -ne 1 -or $read.Response.Length -lt 2 -or
        ($null -ne $read.ReturnValue -and -not [bool]$read.ReturnValue)) {
        throw "Get_Data(0xD7) returned an invalid battery response: $($read.ResponseHex)"
    }
    [byte]$raw = $read.Response[1]
    [int]$limit = $raw -band 0x7F
    if ($limit -notin @(60, 80, 100)) {
        throw "Get_Data(0xD7) returned an unvalidated charge limit $limit (raw=0x$('{0:X2}' -f $raw)); refusing to guess its meaning."
    }
    return [pscustomobject]@{
        Success = $true
        Supported = $true
        ChargeLimitPercent = $limit
        RawValue = [int]$raw
        RawValueHex = ('0x{0:X2}' -f $raw)
        PreservedBit7 = [int]($raw -band 0x80)
        RawResponse = $read.ResponseHex
        Backend = 'DirectWmiAcpi'
        ServiceIndependent = $true
        ReadMethod = 'MSI_ACPI.Get_Data(0xD7)'
    }
}

function Get-MsiDirectBatteryState {
    [CmdletBinding()]
    param()

    $identity = Assert-MsiDirectHardwareIdentity
    $mutex = Enter-MsiDirectAcpiMutex
    try {
        $state = Get-MsiDirectBatteryStateInternal -Context (New-MsiDirectAcpiContext)
        $state | Add-Member -NotePropertyMembers @{
            ApiVersion = $script:ApiVersion
            Operation = 'BatteryStatus'
            Manufacturer = $identity.Manufacturer
            Model = $identity.Model
            AllowedLimitsPercent = @(60, 80, 100)
            MsiPolicy = Get-MsiBatteryPolicyInfo
        }
        return $state
    }
    finally { Exit-MsiDirectAcpiMutex -Mutex $mutex }
}

function Get-MsiDirectBatteryPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(60, 80, 100)][int]$ChargeLimitPercent)

    $state = Get-MsiDirectBatteryState
    [byte]$payload = ($state.RawValue -band 0x80) -bor $ChargeLimitPercent
    return [pscustomobject]@{
        ApiVersion = $script:ApiVersion
        Success = $true
        Operation = 'BatteryPlan'
        CurrentLimitPercent = $state.ChargeLimitPercent
        ChargeLimitPercent = $ChargeLimitPercent
        AlreadyApplied = ($state.ChargeLimitPercent -eq $ChargeLimitPercent)
        CurrentRawValue = $state.RawValueHex
        PlannedRawValue = ('0x{0:X2}' -f $payload)
        Command = ('MSI_ACPI.Set_Data(0xD7, 0x{0:X2})' -f $payload)
        Backend = 'DirectWmiAcpi'
        ServiceIndependent = $true
        PreservesBit7 = $true
        MsiPolicy = $state.MsiPolicy
        RequiresAdministrator = $true
        RequiresConfirmation = $true
        WritesOnPlan = $false
        WritesRegistry = $false
        AutomaticRetry = $false
    }
}

function Set-MsiDirectBatteryLimit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet(60, 80, 100)][int]$ChargeLimitPercent,
        [Parameter(Mandatory = $true)][switch]$ConfirmBatteryChange
    )

    if (-not $ConfirmBatteryChange) { throw 'BatterySet requires -ConfirmBatteryChange.' }
    if (-not (Test-MsiDirectAdministrator)) { throw 'Administrator privileges are required for battery charge-limit writes.' }
    $null = Assert-MsiDirectHardwareIdentity
    $mutex = Enter-MsiDirectAcpiMutex
    $writeSent = $false
    try {
        $context = New-MsiDirectAcpiContext
        $before = Get-MsiDirectBatteryStateInternal -Context $context
        [byte]$payload = ($before.RawValue -band 0x80) -bor $ChargeLimitPercent
        $after = $before
        if ($before.ChargeLimitPercent -ne $ChargeLimitPercent) {
            $writeSent = $true
            $write = Invoke-MsiDirectSetData -Context $context -Address 0xD7 -Value $payload
            if ($write.Flag -ne 1 -or ($null -ne $write.ReturnValue -and -not [bool]$write.ReturnValue)) {
                throw "Set_Data(0xD7) was rejected: $($write.ResponseHex)"
            }
            $after = Get-MsiDirectBatteryStateInternal -Context $context
            if ($after.RawValue -ne $payload) {
                throw "Battery read-back did not match: expected 0x$('{0:X2}' -f $payload), received $($after.RawValueHex). MSI Center may have reapplied its policy."
            }
        }
        return [pscustomobject]@{
            ApiVersion = $script:ApiVersion
            Success = $true
            Operation = 'BatterySet'
            PreviousLimitPercent = $before.ChargeLimitPercent
            ChargeLimitPercent = $after.ChargeLimitPercent
            RawValueHex = $after.RawValueHex
            ReadBackResponse = $after.RawResponse
            AlreadyApplied = (-not $writeSent)
            RequestSent = $writeSent
            Verified = $true
            Backend = 'DirectWmiAcpi'
            ServiceIndependent = $true
            MsiPolicy = Get-MsiBatteryPolicyInfo
            WritesRegistry = $false
            AutomaticRetry = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ApiVersion = $script:ApiVersion
            Success = $false
            Operation = 'BatterySet'
            ChargeLimitPercent = $ChargeLimitPercent
            RequestSent = $writeSent
            Verified = $false
            AutomaticRetry = $false
            Error = ($_.Exception.Message + ' No retry was attempted; refresh the hardware state before another change.')
        }
    }
    finally { Exit-MsiDirectAcpiMutex -Mutex $mutex }
}

function Initialize-MsiFirmwareNativeApi {
    if ('FuckMsiCenter.Native.FirmwareEnvironment' -as [type]) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace FuckMsiCenter.Native
{
    public static class FirmwareEnvironment
    {
        private const UInt32 TOKEN_QUERY = 0x0008;
        private const UInt32 TOKEN_ADJUST_PRIVILEGES = 0x0020;
        private const UInt32 SE_PRIVILEGE_ENABLED = 0x00000002;
        private const Int32 ERROR_NOT_ALL_ASSIGNED = 1300;

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID { public UInt32 LowPart; public Int32 HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES
        {
            public UInt32 PrivilegeCount;
            public LUID Luid;
            public UInt32 Attributes;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, UInt32 access, out IntPtr token);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LookupPrivilegeValue(string systemName, string name, out LUID luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(
            IntPtr token,
            bool disableAll,
            ref TOKEN_PRIVILEGES newState,
            UInt32 bufferLength,
            IntPtr previousState,
            IntPtr returnLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern UInt32 GetFirmwareEnvironmentVariableEx(
            string name,
            string guid,
            byte[] buffer,
            UInt32 size,
            out UInt32 attributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetFirmwareEnvironmentVariableEx(
            string name,
            string guid,
            byte[] buffer,
            UInt32 size,
            UInt32 attributes);

        public static void EnableSystemEnvironmentPrivilege()
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");
            try
            {
                LUID luid;
                if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue failed");
                TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
                privileges.PrivilegeCount = 1;
                privileges.Luid = luid;
                privileges.Attributes = SE_PRIVILEGE_ENABLED;
                if (!AdjustTokenPrivileges(token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "AdjustTokenPrivileges failed");
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_NOT_ALL_ASSIGNED)
                    throw new Win32Exception(error, "SeSystemEnvironmentPrivilege is not available in this process token");
            }
            finally
            {
                CloseHandle(token);
            }
        }

        public static UInt32 Read(string name, string guid, byte[] buffer, out UInt32 attributes)
        {
            EnableSystemEnvironmentPrivilege();
            UInt32 length = GetFirmwareEnvironmentVariableEx(name, guid, buffer, (UInt32)buffer.Length, out attributes);
            if (length == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFirmwareEnvironmentVariableEx failed");
            return length;
        }

        public static void Write(string name, string guid, byte[] buffer, UInt32 length, UInt32 attributes)
        {
            EnableSystemEnvironmentPrivilege();
            if (length == 0 || length > buffer.Length)
                throw new ArgumentOutOfRangeException("length");
            if (!SetFirmwareEnvironmentVariableEx(name, guid, buffer, length, attributes))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetFirmwareEnvironmentVariableEx failed");
        }
    }
}
'@
}

function Get-MsiDirectFirmwareVariable {
    Initialize-MsiFirmwareNativeApi
    [byte[]]$buffer = [byte[]]::new(4096)
    [uint32]$attributes = 0
    [uint32]$length = [FuckMsiCenter.Native.FirmwareEnvironment]::Read(
        $script:FirmwareVariableName,
        $script:FirmwareVariableGuid,
        $buffer,
        [ref]$attributes
    )
    if ($length -lt 6) {
        throw "MsiDCVarData is too short: $length bytes."
    }
    return [pscustomobject]@{
        Name = $script:FirmwareVariableName
        Guid = $script:FirmwareVariableGuid
        Length = [int]$length
        Attributes = [uint32]$attributes
        ExpectedAttributes = [uint32]$script:FirmwareVariableAttributes
        AttributesMatchMsiWriter = ([uint32]$attributes -eq [uint32]$script:FirmwareVariableAttributes)
        Data = $buffer
    }
}

function Set-MsiDirectFirmwareVariable {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Data,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][uint32]$Attributes
    )

    Initialize-MsiFirmwareNativeApi
    if ($Length -le 0 -or $Length -gt $Data.Length) {
        throw "Invalid firmware-variable length $Length for buffer length $($Data.Length)."
    }
    [FuckMsiCenter.Native.FirmwareEnvironment]::Write(
        $script:FirmwareVariableName,
        $script:FirmwareVariableGuid,
        $Data,
        [uint32]$Length,
        $Attributes
    )
}

function Compare-MsiDirectFirmwareData {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Expected,
        [Parameter(Mandatory = $true)][byte[]]$Actual,
        [Parameter(Mandatory = $true)][int]$Length
    )

    if ($Length -lt 0 -or $Expected.Length -lt $Length -or $Actual.Length -lt $Length) {
        return $false
    }
    for ($index = 0; $index -lt $Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            return $false
        }
    }
    return $true
}

function Get-MsiDirectHardwareProbe {
    [CmdletBinding()]
    param(
        [ValidateSet('Full', 'GpuMode')]
        [string]$Capability = 'Full'
    )

    $identity = Assert-MsiDirectHardwareIdentity -Capability $Capability
    $mutex = Enter-MsiDirectAcpiMutex
    try {
        $context = New-MsiDirectAcpiContext
        $webcam = $null
        $fnWin = $null
        if ($Capability -eq 'Full') {
            $webcam = Get-MsiDirectWebCamStateInternal -Context $context
            $fnWin = Invoke-MsiDirectAcpiGet -Context $context -Method Get_Data -Selector 0xE8
            if ($fnWin.Flag -eq 0 -or $fnWin.Response.Length -lt 2) {
                throw "Get_Data(0xE8) returned an invalid response: $($fnWin.ResponseHex)"
            }
        }
        $device = Invoke-MsiDirectAcpiGet -Context $context -Method Get_Device -Selector 0x01
        $ap = Invoke-MsiDirectAcpiGet -Context $context -Method Get_AP -Selector 0x00
        if ($device.Flag -eq 0 -or $device.Response.Length -lt 2) {
            throw "Get_Device(1) returned an invalid response: $($device.ResponseHex)"
        }
        if ($ap.Flag -eq 0 -or $ap.Response.Length -lt 3) {
            throw "Get_AP(0) returned an invalid response: $($ap.ResponseHex)"
        }
    }
    finally {
        Exit-MsiDirectAcpiMutex -Mutex $mutex
    }

    $firmware = $null
    $firmwareError = $null
    try {
        $firmware = Get-MsiDirectFirmwareVariable
    }
    catch {
        $firmwareError = $_.Exception.Message
    }

    $gpu = $null
    if ($null -ne $firmware) {
        [byte]$byte5 = $firmware.Data[5]
        $appliedIndex = [int](($byte5 -band 0x0C) -shr 2)
        $stagedIndex = [int]($byte5 -band 0x03)
        $gpu = [pscustomobject]@{
            UefiByte5 = ('0x{0:X2}' -f $byte5)
            AppliedModeIndex = $appliedIndex
            AppliedMode = if ($appliedIndex -in 0, 1, 2) { $script:ModeNames[$appliedIndex] } else { 'Unknown' }
            StagedTargetIndex = $stagedIndex
            StagedTarget = if ($stagedIndex -in 0, 1, 2) { $script:ModeNames[$stagedIndex] } else { 'Unknown' }
            NewSwitchSupported = (($byte5 -band 0x10) -ne 0)
            IntegratedSupported = (($byte5 -band 0x20) -ne 0)
            DiscreteSupported = (($byte5 -band 0x40) -eq 0)
            FirmwareLength = $firmware.Length
            FirmwareAttributes = ('0x{0:X8}' -f $firmware.Attributes)
            AttributesMatchMsiWriter = $firmware.AttributesMatchMsiWriter
        }
    }

    return [pscustomobject]@{
        ApiVersion = $script:ApiVersion
        Success = $true
        Operation = 'DirectHardwareProbe'
        Manufacturer = $identity.Manufacturer
        Model = $identity.Model
        FirmwareFamily = $identity.FirmwareFamily
        AccessTier = $identity.AccessTier
        HorizontalCompatibility = $identity.HorizontalCompatibility
        AllowedCapabilities = $identity.AllowedCapabilities
        ProbeCapability = $Capability
        Backend = 'WindowsFirmwareApi+DirectWmiAcpi'
        ServiceIndependent = $true
        WritesRegistry = $false
        WritesFirmware = $false
        SendsSetCommand = $false
        WebCam = $webcam
        FnWin = if ($null -ne $fnWin) {
            [pscustomobject]@{
                EcAddress = '0xE8'
                EcByte = ('0x{0:X2}' -f [byte]$fnWin.Response[1])
                EcBit4Set = (([byte]$fnWin.Response[1] -band 0x10) -ne 0)
                RawResponse = $fnWin.ResponseHex
            }
        } else { $null }
        Gpu = $gpu
        FirmwareReadAvailable = ($null -ne $firmware)
        FirmwareReadError = $firmwareError
        GetDeviceResponse = $device.ResponseHex
        GetApResponse = $ap.ResponseHex
        ApPending = (([byte]$ap.Response[2] -band 0x02) -ne 0)
    }
}

function Get-MsiDirectGpuModePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Hybrid', 'Discrete', 'Integrated')]
        [string]$Target,

        [Nullable[byte]]$CurrentUefiByte5,
        [Nullable[byte]]$CurrentApData1
    )

    $targetIndex = [Array]::IndexOf($script:ModeNames, $Target)
    $newByte5 = $null
    if ($null -ne $CurrentUefiByte5) {
        $newByte5 = [byte](([byte]$CurrentUefiByte5 -band 0xFC) -bor $targetIndex)
    }
    $d1Payload = $null
    if ($null -ne $CurrentApData1) {
        $d1Payload = [byte](([byte]$CurrentApData1 -band 0xFC) -bor 0x01)
    }
    return [pscustomobject]@{
        ApiVersion = $script:ApiVersion
        Success = $true
        Operation = 'DirectGpuModePlan'
        Target = $Target
        TargetIndex = $targetIndex
        Backend = 'WindowsFirmwareApi+DirectWmiAcpi'
        ServiceIndependent = $true
        FirmwareVariable = "$($script:FirmwareVariableName) $($script:FirmwareVariableGuid)"
        UefiMutation = 'preserve byte 5 bits 2-7; replace bits 0-1 with target index'
        CurrentUefiByte5 = if ($null -ne $CurrentUefiByte5) { '0x{0:X2}' -f [byte]$CurrentUefiByte5 } else { $null }
        PlannedUefiByte5 = if ($null -ne $newByte5) { '0x{0:X2}' -f [byte]$newByte5 } else { $null }
        FirmwareAttributes = '0x00000007'
        Trigger = if ($null -ne $d1Payload) { 'MSI_ACPI.Set_Data(0xD1, 0x{0:X2})' -f [byte]$d1Payload } else { 'MSI_ACPI.Set_Data(0xD1, (Get_AP(0).Data[1] & 0xFC) | 0x01)' }
        AcceptanceCheck = 'Get_AP(0).Data[1].bit1 == 1'
        Acknowledge = 'MSI_ACPI.Set_Data(0xBE, 0x02)'
        DelayMilliseconds = 2000
        RequiresAdministrator = $true
        RequiresConfirmation = $true
        RequiresManualPowerCycle = $true
        AutomaticRetry = $false
        WritesOnPlan = $false
        ImplementationStatus = 'Validated end-to-end by a service-independent Hybrid-to-Discrete request and post-boot UEFI, MSI_ACPI, and AP-clear verification; used by the production GPU API.'
    }
}

function Request-MsiDirectGpuModeSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Hybrid', 'Discrete', 'Integrated')]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [switch]$ConfirmDirectFirmwareWrite
    )

    if (-not $ConfirmDirectFirmwareWrite) {
        throw 'Request-MsiDirectGpuModeSwitch requires -ConfirmDirectFirmwareWrite. Use Get-MsiDirectGpuModePlan for a side-effect-free preview.'
    }

    $stage = 'Precheck'
    $firmwareWriteSent = $false
    $d1WriteSent = $false
    $beWriteSent = $false
    $requestAccepted = $false
    $mutex = $null
    $beforeFirmwareHex = $null
    $afterFirmwareHex = $null
    $apBeforeHex = $null
    $apAfterHex = $null
    $apFinalHex = $null
    $currentMode = 'Unknown'
    $targetIndex = [Array]::IndexOf($script:ModeNames, $Target)
    $previousByte5 = $null
    $plannedByte5 = $null
    $d1Payload = $null
    $identity = $null

    try {
        if (-not (Test-MsiDirectAdministrator)) {
            throw 'Administrator privileges are required for direct UEFI and MSI_ACPI writes.'
        }
        $identity = Assert-MsiDirectHardwareIdentity -Capability GpuMode
        $mutex = Enter-MsiDirectAcpiMutex
        $context = New-MsiDirectAcpiContext

        $firmware = Get-MsiDirectFirmwareVariable
        if ($firmware.Length -ne 20) {
            throw "Unexpected MsiDCVarData length $($firmware.Length); the live validated length is 20."
        }
        if (-not $firmware.AttributesMatchMsiWriter -or $firmware.Attributes -ne $script:FirmwareVariableAttributes) {
            throw ('Unexpected MsiDCVarData attributes 0x{0:X8}; expected 0x{1:X8}.' -f $firmware.Attributes, $script:FirmwareVariableAttributes)
        }
        $beforeFirmwareHex = Format-MsiDirectBytes -Bytes $firmware.Data -Maximum $firmware.Length
        [byte]$previousByte5 = $firmware.Data[5]
        $currentIndex = [int](($previousByte5 -band 0x0C) -shr 2)
        if ($currentIndex -notin 0, 1, 2) {
            throw "Firmware applied-mode bits contain unknown value $currentIndex."
        }
        $currentMode = $script:ModeNames[$currentIndex]
        $stagedIndex = [int]($previousByte5 -band 0x03)
        if ($stagedIndex -ne $currentIndex) {
            throw "UEFI target bits ($stagedIndex) do not match applied-mode bits ($currentIndex); refusing to overwrite a possibly staged request."
        }
        if (($previousByte5 -band 0x10) -eq 0) {
            throw 'UEFI reports that the new GPU switch mechanism is unsupported.'
        }
        if ($Target -eq 'Integrated' -and ($previousByte5 -band 0x20) -eq 0) {
            throw 'UEFI reports that Integrated mode is unsupported.'
        }
        if ($Target -eq 'Discrete' -and ($previousByte5 -band 0x40) -ne 0) {
            throw 'UEFI reports that Discrete mode is unsupported.'
        }

        $deviceBefore = Invoke-MsiDirectAcpiGet -Context $context -Method Get_Device -Selector 0x01
        if ($deviceBefore.Flag -eq 0 -or $deviceBefore.Response.Length -lt 2) {
            throw "Get_Device(1) returned invalid state: $($deviceBefore.ResponseHex)"
        }
        $legacyDiscrete = (([byte]$deviceBefore.Response[1] -band 0x40) -ne 0)
        if ($currentMode -eq 'Discrete' -and -not $legacyDiscrete) {
            throw 'UEFI says Discrete but Get_Device(1).Data[0].bit6 is clear.'
        }
        if ($currentMode -ne 'Discrete' -and $legacyDiscrete) {
            throw "UEFI says $currentMode but Get_Device(1).Data[0].bit6 is set."
        }

        $apBefore = Invoke-MsiDirectAcpiGet -Context $context -Method Get_AP -Selector 0x00
        $apBeforeHex = $apBefore.ResponseHex
        if ($apBefore.Flag -eq 0 -or $apBefore.Response.Length -lt 3) {
            throw "Get_AP(0) returned invalid state: $apBeforeHex"
        }
        if (([byte]$apBefore.Response[2] -band 0x02) -ne 0) {
            throw "Get_AP(0) already has the pending bit set: $apBeforeHex"
        }
        [byte]$d1Payload = (([byte]$apBefore.Response[2] -band 0xFC) -bor 0x01)
        if ($d1Payload -ne 0x01) {
            throw ('Unexpected preserved high bits in Get_AP(0).Data[1]; D1 payload would be 0x{0:X2}.' -f $d1Payload)
        }

        if ($currentMode -eq $Target) {
            return [pscustomobject]@{
                ApiVersion = $script:ApiVersion
                Success = $true
                Operation = 'DirectGpuModeRequest'
                Backend = 'WindowsFirmwareApi+DirectWmiAcpi'
                ServiceIndependent = $true
                Manufacturer = $identity.Manufacturer
                Model = $identity.Model
                FirmwareFamily = $identity.FirmwareFamily
                AccessTier = $identity.AccessTier
                HorizontalCompatibility = $identity.HorizontalCompatibility
                Target = $Target
                TargetIndex = $targetIndex
                PreviousMode = $currentMode
                AlreadyApplied = $true
                FirmwareWriteSent = $false
                D1WriteSent = $false
                BEWriteSent = $false
                RequestAccepted = $false
                ManualPowerCycleNeeded = $false
                AutomaticRetry = $false
                Stage = 'AlreadyApplied'
            }
        }

        [byte[]]$writeData = [byte[]]::new($firmware.Length)
        [Array]::Copy($firmware.Data, $writeData, $firmware.Length)
        [byte]$plannedByte5 = (($previousByte5 -band 0xFC) -bor $targetIndex)
        $writeData[5] = $plannedByte5

        $stage = 'WriteUefiTarget'
        Set-MsiDirectFirmwareVariable -Data $writeData -Length $firmware.Length -Attributes $firmware.Attributes
        $firmwareWriteSent = $true

        $stage = 'VerifyUefiTarget'
        $firmwareAfter = Get-MsiDirectFirmwareVariable
        $afterFirmwareHex = Format-MsiDirectBytes -Bytes $firmwareAfter.Data -Maximum $firmwareAfter.Length
        if ($firmwareAfter.Length -ne $firmware.Length -or $firmwareAfter.Attributes -ne $firmware.Attributes) {
            throw 'UEFI target write returned, but length or attributes changed. D1 was not sent.'
        }
        if (-not (Compare-MsiDirectFirmwareData -Expected $writeData -Actual $firmwareAfter.Data -Length $firmware.Length)) {
            throw 'UEFI target write did not read back byte-for-byte. D1 was not sent.'
        }

        $stage = 'WriteD1Trigger'
        $d1 = Invoke-MsiDirectSetData -Context $context -Address 0xD1 -Value $d1Payload
        $d1WriteSent = $true
        if ($d1.Flag -eq 0) {
            throw "Set_Data(0xD1) returned Flag=0: $($d1.ResponseHex)"
        }

        $stage = 'WaitForAcceptance'
        Start-Sleep -Milliseconds 2000
        $apAccepted = $null
        for ($attempt = 1; $attempt -le 33; $attempt++) {
            $apAccepted = Invoke-MsiDirectAcpiGet -Context $context -Method Get_AP -Selector 0x00
            $apAfterHex = $apAccepted.ResponseHex
            if ($apAccepted.Flag -gt 0 -and $apAccepted.Response.Length -ge 3 -and
                (([byte]$apAccepted.Response[2] -band 0x02) -ne 0)) {
                $requestAccepted = $true
                break
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $requestAccepted) {
            throw "D1 returned success but AP pending bit was not observed: $apAfterHex"
        }

        $stage = 'WriteBEAcknowledgement'
        $be = Invoke-MsiDirectSetData -Context $context -Address 0xBE -Value 0x02
        $beWriteSent = $true
        if ($be.Flag -eq 0) {
            throw "Set_Data(0xBE,0x02) returned Flag=0: $($be.ResponseHex)"
        }

        $stage = 'FinalReadBack'
        $apFinal = Invoke-MsiDirectAcpiGet -Context $context -Method Get_AP -Selector 0x00
        $apFinalHex = $apFinal.ResponseHex
        if ($apFinal.Flag -eq 0 -or $apFinal.Response.Length -lt 3 -or
            (([byte]$apFinal.Response[2] -band 0x02) -eq 0)) {
            throw "Final Get_AP(0) did not retain the accepted pending state: $apFinalHex"
        }
        $firmwareFinal = Get-MsiDirectFirmwareVariable
        if ($firmwareFinal.Length -ne $firmware.Length -or $firmwareFinal.Attributes -ne $firmware.Attributes) {
            throw 'Final UEFI length or attributes changed. No retry was attempted.'
        }
        if (-not (Compare-MsiDirectFirmwareData -Expected $writeData -Actual $firmwareFinal.Data -Length $firmware.Length)) {
            throw 'Final UEFI read-back no longer matches the staged target. No retry was attempted.'
        }

        return [pscustomobject]@{
            ApiVersion = $script:ApiVersion
            Success = $true
            Operation = 'DirectGpuModeRequest'
            Backend = 'WindowsFirmwareApi+DirectWmiAcpi'
            ServiceIndependent = $true
            Manufacturer = $identity.Manufacturer
            Model = $identity.Model
            FirmwareFamily = $identity.FirmwareFamily
            AccessTier = $identity.AccessTier
            HorizontalCompatibility = $identity.HorizontalCompatibility
            Target = $Target
            TargetIndex = $targetIndex
            PreviousMode = $currentMode
            PreviousUefiByte5 = ('0x{0:X2}' -f $previousByte5)
            PlannedUefiByte5 = ('0x{0:X2}' -f $plannedByte5)
            FirmwareLength = $firmware.Length
            FirmwareAttributes = ('0x{0:X8}' -f $firmware.Attributes)
            FirmwareBefore = $beforeFirmwareHex
            FirmwareAfter = $afterFirmwareHex
            D1Payload = ('0x{0:X2}' -f $d1Payload)
            GetApBefore = $apBeforeHex
            GetApAfterD1 = $apAfterHex
            GetApFinal = $apFinalHex
            FirmwareWriteSent = $firmwareWriteSent
            D1WriteSent = $d1WriteSent
            BEWriteSent = $beWriteSent
            RequestAccepted = $requestAccepted
            AlreadyApplied = $false
            ManualPowerCycleNeeded = $true
            AutomaticRetry = $false
            Stage = 'Complete'
        }
    }
    catch {
        return [pscustomobject]@{
            ApiVersion = $script:ApiVersion
            Success = $false
            Operation = 'DirectGpuModeRequest'
            Backend = 'WindowsFirmwareApi+DirectWmiAcpi'
            ServiceIndependent = $true
            Target = $Target
            TargetIndex = $targetIndex
            PreviousMode = $currentMode
            PreviousUefiByte5 = if ($null -ne $previousByte5) { '0x{0:X2}' -f [byte]$previousByte5 } else { $null }
            PlannedUefiByte5 = if ($null -ne $plannedByte5) { '0x{0:X2}' -f [byte]$plannedByte5 } else { $null }
            D1Payload = if ($null -ne $d1Payload) { '0x{0:X2}' -f [byte]$d1Payload } else { $null }
            FirmwareBefore = $beforeFirmwareHex
            FirmwareAfter = $afterFirmwareHex
            GetApBefore = $apBeforeHex
            GetApAfterD1 = $apAfterHex
            GetApFinal = $apFinalHex
            FirmwareWriteSent = $firmwareWriteSent
            D1WriteSent = $d1WriteSent
            BEWriteSent = $beWriteSent
            RequestAccepted = $requestAccepted
            AlreadyApplied = $false
            ManualPowerCycleNeeded = $false
            AutomaticRetry = $false
            DoNotRetryAutomatically = ($firmwareWriteSent -or $d1WriteSent -or $beWriteSent)
            FirmwareTargetMayBeStaged = $firmwareWriteSent
            Stage = $stage
            Error = $_.Exception.Message
            ExceptionType = $_.Exception.GetType().FullName
            HResult = ('0x{0:X8}' -f $_.Exception.HResult)
        }
    }
    finally {
        if ($null -ne $mutex) {
            Exit-MsiDirectAcpiMutex -Mutex $mutex
        }
    }
}

Export-ModuleMember -Function `
    Get-MsiDirectBatteryState, `
    Get-MsiDirectBatteryPlan, `
    Set-MsiDirectBatteryLimit, `
    Get-MsiDirectWebCamState, `
    Get-MsiDirectWebCamPlan, `
    Set-MsiDirectWebCamState, `
    Get-MsiDirectHardwareProbe, `
    Get-MsiDirectGpuModePlan, `
    Request-MsiDirectGpuModeSwitch
