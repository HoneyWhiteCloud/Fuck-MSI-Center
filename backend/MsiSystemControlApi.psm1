# Allowlisted MSI system-control API.
#
# WebCam uses root/WMI:MSI_ACPI directly and therefore does not depend on Base
# Module or CentralServer.  Controls without a proven service-free equivalent
# retain the signed MSI service path.  Set requires explicit confirmation,
# performs at most one request, and verifies the result with a fresh read.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ApiVersion = '0.3.0'
$script:ExpectedManufacturerPattern = 'Micro-Star|MSI'
$script:ExpectedModel = 'Sword 16 HX B14VGKG'
$script:ExpectedPort = 32683
$script:ExpectedDestinationId = 104
$script:ExpectedBaseModuleVersion = '1.0.2606.0801'
$script:ExpectedCentralServerVersion = '3.2026.0427.01'
$script:ExpectedInitialized = 1001
# Keep the legacy mutex identity so older releases serialize the same service.
$script:CentralServerMutexName = 'Local\MsiGpuModeGui-CentralServer-32683'
$script:SdkKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\SDK'
$script:BaseModuleKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module'
$script:BiosKey = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
$script:CentralServerPath = 'C:\Program Files (x86)\MSI\MSI Center\MSI.CentralServer.exe'
$script:BaseModulePath = 'C:\Program Files (x86)\MSI\MSI Center\Base Module\API_NB_Base Module.dll'
$script:DirectHardwareModule = Join-Path $PSScriptRoot 'MsiDirectHardwareApi.psd1'

Import-Module $script:DirectHardwareModule -ErrorAction Stop

$script:FeatureDefinitions = [ordered]@{
    WebCam = [pscustomobject]@{
        Feature     = 'WebCam'
        DisplayName = 'Webcam hardware switch'
        Backend     = 'DirectWmiAcpi'
        SideEffects = @(
            'The direct backend reads MSI_ACPI.Get_Device(1), changes Data[0].bit1, and writes MSI_ACPI.Set_Data(0x2E).',
            'The integrated webcam becomes unavailable immediately when disabled.'
        )
    }
    WinKey = [pscustomobject]@{
        Feature     = 'WinKey'
        DisplayName = 'Windows key'
        Backend     = 'CentralServerKeyboardHook'
        SideEffects = @(
            'MSI Base Module updates GeneralSetting WinKey and ONEMSI.',
            'OmApSvcBroker observes WinKey and changes its Windows-key keyboard-hook policy.'
        )
    }
    SwitchFnWin = [pscustomobject]@{
        Feature     = 'SwitchFnWin'
        DisplayName = 'Fn / Windows key position swap'
        Backend     = 'CentralServerEcUefiHid'
        SideEffects = @(
            'MSI Base Module updates GeneralSetting WinFn and ONEMSI and may send a keyboard-MCU HID command.',
            'OmApSvcBroker observes WinFn and can persist the official Win/Fn flag through its EC/UEFI path.'
        )
    }
}

function Enter-MsiSystemMutex {
    $mutex = [Threading.Mutex]::new($false, $script:CentralServerMutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(10000)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw 'Timed out waiting for exclusive access to MSI CentralServer port 32683.'
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-MsiSystemMutex {
    param([Parameter(Mandatory = $true)][Threading.Mutex]$Mutex)

    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}

function Format-MsiSystemBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return (($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
}

function New-MsiSystemFrame {
    param(
        [Parameter(Mandatory = $true)][int]$DestinationId,
        [Parameter(Mandatory = $true)][string]$CommandText
    )

    [byte[]]$commandBytes = [Text.Encoding]::UTF8.GetBytes($CommandText)
    [byte[]]$frame = [byte[]]::new(6 + $commandBytes.Length)
    [BitConverter]::GetBytes($DestinationId).CopyTo($frame, 0)
    $frame[4] = 0x00
    $frame[5] = 0x13
    $commandBytes.CopyTo($frame, 6)
    return $frame
}

function Test-MsiSignedFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required MSI component was not found: $Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($null -ne $signature.SignerCertificate) {
        [string]$signature.SignerCertificate.Subject
    }
    else {
        ''
    }
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $subject -notmatch 'Micro-Star') {
        throw "MSI component signature validation failed: $Path (status=$($signature.Status), signer=$subject)"
    }

    return [pscustomobject]@{
        Path    = $Path
        Version = [string](Get-Item -LiteralPath $Path).VersionInfo.FileVersion
        Signer  = $subject
    }
}

function Get-MsiSystemContext {
    $bios = Get-ItemProperty -LiteralPath $script:BiosKey
    $manufacturer = [string]$bios.SystemManufacturer
    $model = [string]$bios.SystemProductName
    if ($manufacturer -notmatch $script:ExpectedManufacturerPattern -or $model -ne $script:ExpectedModel) {
        throw "Hardware identity is not the validated MSI $($script:ExpectedModel): manufacturer=$manufacturer, model=$model"
    }

    $sdk = Get-ItemProperty -LiteralPath $script:SdkKey
    $baseModule = Get-ItemProperty -LiteralPath $script:BaseModuleKey
    $port = [int]$sdk.'Server Port'
    $destinationId = [int]$baseModule.ID
    $serverPid = [int]$sdk.PID
    $baseVersion = [string]$baseModule.Version
    $initialized = [int]$baseModule.Initialized

    if ($port -ne $script:ExpectedPort) {
        throw "Unexpected MSI CentralServer port $port; expected $($script:ExpectedPort)."
    }
    if ($destinationId -ne $script:ExpectedDestinationId) {
        throw "Unexpected Base Module component ID $destinationId; expected $($script:ExpectedDestinationId)."
    }
    if ($initialized -ne $script:ExpectedInitialized) {
        throw "MSI Base Module is not initialized (value=$initialized)."
    }

    $serverProcess = Get-Process -Id $serverPid -ErrorAction Stop
    if ($serverProcess.ProcessName -ne 'MSI.CentralServer') {
        throw "Registry PID $serverPid belongs to $($serverProcess.ProcessName), not MSI.CentralServer."
    }

    $serverFile = Test-MsiSignedFile -Path $script:CentralServerPath
    $baseFile = Test-MsiSignedFile -Path $script:BaseModulePath
    $compatibilityWarnings = [Collections.Generic.List[string]]::new()
    if ($serverFile.Version -ne $script:ExpectedCentralServerVersion) {
        $compatibilityWarnings.Add(
            "Installed MSI.CentralServer.exe version $($serverFile.Version) differs from validated version $($script:ExpectedCentralServerVersion); the protocol may still be compatible, but this version is unverified."
        )
    }
    if ($baseVersion -ne $script:ExpectedBaseModuleVersion) {
        $compatibilityWarnings.Add(
            "Base Module Registry version $baseVersion differs from validated version $($script:ExpectedBaseModuleVersion); feature compatibility will be checked through IsSupport/Get and read-back."
        )
    }
    if ($baseFile.Version -ne $script:ExpectedBaseModuleVersion) {
        $compatibilityWarnings.Add(
            "Installed API_NB_Base Module.dll version $($baseFile.Version) differs from validated version $($script:ExpectedBaseModuleVersion); this signed MSI version is allowed with a compatibility warning."
        )
    }

    return [pscustomobject]@{
        Manufacturer       = $manufacturer
        Model              = $model
        Port               = $port
        DestinationId      = $destinationId
        ServerPid          = $serverPid
        BaseModuleVersion  = $baseVersion
        CentralServer      = $serverFile
        BaseModule         = $baseFile
        VersionMatchesValidatedStack = $compatibilityWarnings.Count -eq 0
        CompatibilityWarnings = [string[]]$compatibilityWarnings.ToArray()
    }
}

function Invoke-MsiSystemCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('IsSupport', 'Get', 'Set')][string]$Verb,
        [Parameter(Mandatory = $true)][ValidateSet('WebCam', 'WinKey', 'SwitchFnWin')][string]$Feature,
        [Nullable[int]]$Value
    )

    if ($Verb -eq 'Set') {
        if ($null -eq $Value -or [int]$Value -notin 0, 1) {
            throw 'Set requires a value of 0 or 1.'
        }
        $command = "$Verb;$Feature;$([int]$Value)"
    }
    else {
        if ($null -ne $Value) {
            throw "$Verb does not accept a value."
        }
        $command = "$Verb;$Feature"
    }

    [byte[]]$frame = New-MsiSystemFrame -DestinationId $Context.DestinationId -CommandText $command
    $client = [Net.Sockets.TcpClient]::new()
    $client.ReceiveTimeout = 3000
    $client.SendTimeout = 3000
    try {
        $client.Connect([Net.IPAddress]::Loopback, $Context.Port)
        $stream = $client.GetStream()
        $stream.Write($frame, 0, $frame.Length)
        $stream.Flush()

        [byte[]]$buffer = [byte[]]::new(8192)
        $count = $stream.Read($buffer, 0, $buffer.Length)
        if ($count -le 0) {
            throw 'MSI CentralServer closed the connection without a response.'
        }
        $responseText = [Text.Encoding]::UTF8.GetString($buffer, 0, $count)
    }
    finally {
        $client.Dispose()
    }

    $parts = @($responseText.Split(';'))
    if ($parts.Count -ne 3 -or $parts[0] -cne $Verb -or $parts[1] -cne $Feature) {
        throw "Unexpected MSI CentralServer response for $command`: $responseText"
    }

    return [pscustomobject]@{
        Command      = $command
        FrameHex     = Format-MsiSystemBytes -Bytes $frame
        ResponseText = $responseText
        Result       = [string]$parts[2]
    }
}

function Get-MsiSystemFeatureState {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('WebCam', 'WinKey', 'SwitchFnWin')][string]$Feature
    )

    if ($Feature -eq 'WebCam') {
        $direct = Get-MsiDirectWebCamState
        return [pscustomobject]@{
            Feature         = 'WebCam'
            DisplayName     = $script:FeatureDefinitions.WebCam.DisplayName
            Supported       = [bool]$direct.Supported
            Enabled         = [bool]$direct.Enabled
            SupportResponse = $direct.ReadMethod
            StatusResponse  = $direct.RawResponse
            Backend         = $direct.Backend
            ServiceIndependent = $true
        }
    }

    $support = Invoke-MsiSystemCommand -Context $Context -Verb IsSupport -Feature $Feature
    if ($support.Result -notin 'Supported', 'NotSupported') {
        throw "Unknown support response for $Feature`: $($support.ResponseText)"
    }

    $supported = $support.Result -eq 'Supported'
    $enabled = $null
    $get = $null
    if ($supported) {
        $get = Invoke-MsiSystemCommand -Context $Context -Verb Get -Feature $Feature
        if ($get.Result -notin '0', '1') {
            throw "Unknown status response for $Feature`: $($get.ResponseText)"
        }
        $enabled = $get.Result -eq '1'
    }

    $definition = $script:FeatureDefinitions[$Feature]
    return [pscustomobject]@{
        Feature         = $Feature
        DisplayName     = $definition.DisplayName
        Supported       = $supported
        Enabled         = $enabled
        SupportResponse = $support.ResponseText
        StatusResponse  = if ($null -ne $get) { $get.ResponseText } else { $null }
        Backend         = $script:FeatureDefinitions[$Feature].Backend
        ServiceIndependent = $false
    }
}

function New-MsiUnavailableSystemFeatureState {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('WinKey', 'SwitchFnWin')][string]$Feature,
        [Parameter(Mandatory = $true)][string]$Error
    )

    return [pscustomobject]@{
        Feature = $Feature
        DisplayName = $script:FeatureDefinitions[$Feature].DisplayName
        Supported = $false
        Enabled = $null
        SupportResponse = $null
        StatusResponse = $null
        Backend = $script:FeatureDefinitions[$Feature].Backend
        ServiceIndependent = $false
        UnavailableReason = $Error
    }
}

function Get-MsiSystemControlStatus {
    [CmdletBinding()]
    param()

    $controls = [ordered]@{}
    $directWebCamError = $null
    try {
        $controls.WebCam = Get-MsiSystemFeatureState -Context $null -Feature WebCam
    }
    catch {
        $directWebCamError = $_.Exception.Message
    }

    $context = $null
    $centralError = $null
    $mutex = Enter-MsiSystemMutex
    try {
        try {
            $context = Get-MsiSystemContext
            if (-not $controls.Contains('WebCam')) {
                $fallbackSupport = Invoke-MsiSystemCommand -Context $context -Verb IsSupport -Feature WebCam
                if ($fallbackSupport.Result -notin 'Supported', 'NotSupported') {
                    throw "Unknown support response for WebCam: $($fallbackSupport.ResponseText)"
                }
                $fallbackEnabled = $null
                $fallbackStatus = $null
                if ($fallbackSupport.Result -eq 'Supported') {
                    $fallbackStatus = Invoke-MsiSystemCommand -Context $context -Verb Get -Feature WebCam
                    if ($fallbackStatus.Result -notin '0', '1') {
                        throw "Unknown status response for WebCam: $($fallbackStatus.ResponseText)"
                    }
                    $fallbackEnabled = $fallbackStatus.Result -eq '1'
                }
                $controls.WebCam = [pscustomobject]@{
                    Feature = 'WebCam'
                    DisplayName = $script:FeatureDefinitions.WebCam.DisplayName
                    Supported = ($fallbackSupport.Result -eq 'Supported')
                    Enabled = $fallbackEnabled
                    SupportResponse = $fallbackSupport.ResponseText
                    StatusResponse = if ($null -ne $fallbackStatus) { $fallbackStatus.ResponseText } else { $null }
                    Backend = 'CentralServerFallback'
                    ServiceIndependent = $false
                    DirectBackendError = $directWebCamError
                }
            }
            foreach ($feature in 'WinKey', 'SwitchFnWin') {
                $controls[$feature] = Get-MsiSystemFeatureState -Context $context -Feature $feature
            }
        }
        catch {
            $centralError = $_.Exception.Message
            foreach ($feature in 'WinKey', 'SwitchFnWin') {
                $controls[$feature] = New-MsiUnavailableSystemFeatureState -Feature $feature -Error $centralError
            }
        }
    }
    finally {
        Exit-MsiSystemMutex -Mutex $mutex
    }

    if (-not $controls.Contains('WebCam')) {
        throw "Direct WebCam status failed ($directWebCamError), and no CentralServer fallback was available ($centralError)."
    }

    $compatibilityWarnings = if ($null -ne $context) { [string[]]$context.CompatibilityWarnings } else { [string[]]@() }
    return [pscustomobject]@{
            ApiVersion          = $script:ApiVersion
            Success             = $true
            Operation           = 'SystemStatus'
            Manufacturer        = if ($null -ne $context) { $context.Manufacturer } else { $null }
            Model               = if ($null -ne $context) { $context.Model } else { $script:ExpectedModel }
            CentralServerAvailable = ($null -ne $context)
            CentralServerError  = $centralError
            CentralServerPort   = if ($null -ne $context) { $context.Port } else { $null }
            DestinationId       = if ($null -ne $context) { $context.DestinationId } else { $null }
            CentralServerPid    = if ($null -ne $context) { $context.ServerPid } else { $null }
            CentralServerVersion = if ($null -ne $context) { $context.CentralServer.Version } else { $null }
            BaseModuleVersion   = if ($null -ne $context) { $context.BaseModuleVersion } else { $null }
            BaseModuleFileVersion = if ($null -ne $context) { $context.BaseModule.Version } else { $null }
            ValidatedCentralServerVersion = $script:ExpectedCentralServerVersion
            ValidatedBaseModuleVersion = $script:ExpectedBaseModuleVersion
            VersionMatchesValidatedStack = if ($null -ne $context) { $context.VersionMatchesValidatedStack } else { $false }
            CompatibilityWarnings = $compatibilityWarnings
            Controls            = [pscustomobject]$controls
            WritesRegistry      = $false
            WritesFirmware      = $false
            SendsSetCommand     = $false
    }
}

function Get-MsiSystemControlPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('WebCam', 'WinKey', 'SwitchFnWin')]
        [string]$Feature,

        [Parameter(Mandatory = $true)]
        [bool]$Enabled
    )

    if ($Feature -eq 'WebCam') {
        try {
            $directPlan = Get-MsiDirectWebCamPlan -Enabled $Enabled
            $currentEnabled = [bool]$directPlan.CurrentEnabled
            $alreadyApplied = [bool]$directPlan.AlreadyApplied
            $writeMethod = [string]$directPlan.WriteMethod
        }
        catch {
            # A non-elevated caller may be unable to read MSI_ACPI. Use the
            # official read-only query as a status fallback; execution still
            # uses the direct backend after the administrator guard.
            $mutex = Enter-MsiSystemMutex
            try {
                $fallbackContext = Get-MsiSystemContext
                $fallbackState = Invoke-MsiSystemCommand -Context $fallbackContext -Verb IsSupport -Feature WebCam
                if ($fallbackState.Result -ne 'Supported') {
                    throw 'WebCam is not supported by the installed MSI firmware.'
                }
                $fallbackGet = Invoke-MsiSystemCommand -Context $fallbackContext -Verb Get -Feature WebCam
                if ($fallbackGet.Result -notin '0', '1') {
                    throw "Unknown WebCam status response: $($fallbackGet.ResponseText)"
                }
                $currentEnabled = $fallbackGet.Result -eq '1'
                $alreadyApplied = ($currentEnabled -eq $Enabled)
                $writeMethod = 'MSI_ACPI.Set_Data(0x2E, read-modify-write payload calculated at execution time)'
            }
            finally {
                Exit-MsiSystemMutex -Mutex $mutex
            }
        }
        $definition = $script:FeatureDefinitions.WebCam
        return [pscustomobject]@{
            ApiVersion = $script:ApiVersion
            Success = $true
            Operation = 'SystemPlan'
            Feature = 'WebCam'
            DisplayName = $definition.DisplayName
            CurrentEnabled = $currentEnabled
            TargetEnabled = $Enabled
            AlreadyApplied = $alreadyApplied
            Command = $writeMethod
            FrameHex = $null
            Backend = 'DirectWmiAcpi'
            ServiceIndependent = $true
            CentralServerPort = $null
            CentralServerVersion = $null
            BaseModuleVersion = $null
            BaseModuleFileVersion = $null
            ValidatedCentralServerVersion = $script:ExpectedCentralServerVersion
            ValidatedBaseModuleVersion = $script:ExpectedBaseModuleVersion
            VersionMatchesValidatedStack = $true
            CompatibilityWarnings = [string[]]@()
            DestinationId = $null
            RequiresAdministrator = $true
            RequiresConfirmation = $true
            AutomaticRetry = $false
            SideEffects = @($definition.SideEffects)
            WritesOnPlan = $false
        }
    }

    $mutex = Enter-MsiSystemMutex
    try {
        $context = Get-MsiSystemContext
        $state = Get-MsiSystemFeatureState -Context $context -Feature $Feature
        if (-not $state.Supported) {
            throw "$Feature is not supported by the installed MSI Base Module on this machine."
        }

        $value = if ($Enabled) { 1 } else { 0 }
        $command = "Set;$Feature;$value"
        [byte[]]$frame = New-MsiSystemFrame -DestinationId $context.DestinationId -CommandText $command
        $definition = $script:FeatureDefinitions[$Feature]
        return [pscustomobject]@{
            ApiVersion            = $script:ApiVersion
            Success               = $true
            Operation             = 'SystemPlan'
            Feature               = $Feature
            DisplayName           = $definition.DisplayName
            CurrentEnabled        = [bool]$state.Enabled
            TargetEnabled         = $Enabled
            AlreadyApplied        = ([bool]$state.Enabled -eq $Enabled)
            Command               = $command
            FrameHex              = Format-MsiSystemBytes -Bytes $frame
            CentralServerPort     = $context.Port
            CentralServerVersion  = $context.CentralServer.Version
            BaseModuleVersion     = $context.BaseModuleVersion
            BaseModuleFileVersion = $context.BaseModule.Version
            ValidatedCentralServerVersion = $script:ExpectedCentralServerVersion
            ValidatedBaseModuleVersion = $script:ExpectedBaseModuleVersion
            VersionMatchesValidatedStack = $context.VersionMatchesValidatedStack
            CompatibilityWarnings = [string[]]$context.CompatibilityWarnings
            DestinationId         = $context.DestinationId
            Backend               = $definition.Backend
            ServiceIndependent    = $false
            RequiresAdministrator = $true
            RequiresConfirmation  = $true
            AutomaticRetry        = $false
            SideEffects           = @($definition.SideEffects)
            WritesOnPlan          = $false
        }
    }
    finally {
        Exit-MsiSystemMutex -Mutex $mutex
    }
}

function Set-MsiSystemControl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('WebCam', 'WinKey', 'SwitchFnWin')]
        [string]$Feature,

        [Parameter(Mandatory = $true)]
        [bool]$Enabled,

        [Parameter(Mandatory = $true)]
        [switch]$ConfirmSystemChange
    )

    if (-not $ConfirmSystemChange) {
        throw 'Set-MsiSystemControl requires -ConfirmSystemChange. Use Get-MsiSystemControlPlan for a side-effect-free preview.'
    }
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required for MSI system-control writes.'
    }

    if ($Feature -eq 'WebCam') {
        $direct = Set-MsiDirectWebCamState -Enabled $Enabled -ConfirmSystemChange
        return [pscustomobject]@{
            ApiVersion = $script:ApiVersion
            Success = [bool]$direct.Success
            Operation = 'SystemSet'
            Feature = 'WebCam'
            PreviousEnabled = [bool]$direct.PreviousEnabled
            Enabled = [bool]$direct.Enabled
            AlreadyApplied = [bool]$direct.AlreadyApplied
            RequestSent = [bool]$direct.RequestSent
            Verified = [bool]$direct.Verified
            Backend = 'DirectWmiAcpi'
            ServiceIndependent = $true
            Command = if ($null -ne $direct.PSObject.Properties['WriteMethod']) { $direct.WriteMethod } else { $null }
            ReadBackResponse = if ($null -ne $direct.PSObject.Properties['ReadBackResponse']) { $direct.ReadBackResponse } else { $null }
            AutomaticRetry = $false
            VersionMatchesValidatedStack = $true
            CompatibilityWarnings = [string[]]@()
        }
    }

    $mutex = Enter-MsiSystemMutex
    try {
        $context = Get-MsiSystemContext
        $before = Get-MsiSystemFeatureState -Context $context -Feature $Feature
        if (-not $before.Supported) {
            throw "$Feature is not supported by the installed MSI Base Module on this machine."
        }
        if ([bool]$before.Enabled -eq $Enabled) {
            return [pscustomobject]@{
                ApiVersion       = $script:ApiVersion
                Success          = $true
                Operation        = 'SystemSet'
                Feature          = $Feature
                PreviousEnabled  = [bool]$before.Enabled
                Enabled          = [bool]$before.Enabled
                AlreadyApplied   = $true
                RequestSent      = $false
                Verified         = $true
                AutomaticRetry   = $false
                Backend          = $script:FeatureDefinitions[$Feature].Backend
                ServiceIndependent = $false
                VersionMatchesValidatedStack = $context.VersionMatchesValidatedStack
                CompatibilityWarnings = [string[]]$context.CompatibilityWarnings
            }
        }

        $value = if ($Enabled) { 1 } else { 0 }
        $set = Invoke-MsiSystemCommand -Context $context -Verb Set -Feature $Feature -Value $value
        $after = Get-MsiSystemFeatureState -Context $context -Feature $Feature
        $verified = $after.Supported -and ([bool]$after.Enabled -eq $Enabled)
        if (-not $verified) {
            throw "MSI accepted a Set response but read-back did not match for $Feature. No retry was attempted. Response=$($set.ResponseText)"
        }

        return [pscustomobject]@{
            ApiVersion       = $script:ApiVersion
            Success          = $true
            Operation        = 'SystemSet'
            Feature          = $Feature
            PreviousEnabled  = [bool]$before.Enabled
            Enabled          = [bool]$after.Enabled
            AlreadyApplied   = $false
            RequestSent      = $true
            Verified         = $true
            Command          = $set.Command
            ResponseText     = $set.ResponseText
            ReadBackResponse = $after.StatusResponse
            AutomaticRetry   = $false
            Backend          = $script:FeatureDefinitions[$Feature].Backend
            ServiceIndependent = $false
            VersionMatchesValidatedStack = $context.VersionMatchesValidatedStack
            CompatibilityWarnings = [string[]]$context.CompatibilityWarnings
        }
    }
    finally {
        Exit-MsiSystemMutex -Mutex $mutex
    }
}

Export-ModuleMember -Function Get-MsiSystemControlStatus, Get-MsiSystemControlPlan, Set-MsiSystemControl
