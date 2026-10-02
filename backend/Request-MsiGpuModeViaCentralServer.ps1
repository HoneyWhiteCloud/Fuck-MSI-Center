# Controlled MSI MUX switch request through MSI Center's CentralServer service.
# This is a research harness for MSI Sword 16 HX B14VGKG, not the final CLI.
# Without -ConfirmRegistryAndFirmwareWrite it only prints the exact planned sequence.
# It never starts shutdown.exe and never restarts or powers off Windows.

#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Hybrid', 'Discrete', 'Integrated')]
    [string]$Target,

    [switch]$ConfirmRegistryAndFirmwareWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedModel = 'Sword 16 HX B14VGKG'
$expectedInstance = 'ACPI\PNP0C14\0_0'
$expectedPort = 32683
$expectedDestinationId = 104
$sdkKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\SDK'
$baseModuleKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module'
$generalSettingKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module\GeneralSetting'
$biosKey = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
$wmiLogPath = 'C:\Program Files (x86)\MSI\NoteBook\MSI NBFoundation Service\WmiAcpi2.log'
$registryStaged = $false

function Format-HResult {
    param([int]$Value)
    return ('0x{0:X8}' -f $Value)
}

function Format-Bytes {
    param([byte[]]$Bytes, [int]$Maximum = 0)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ''
    }

    $count = if ($Maximum -gt 0) { [Math]::Min($Maximum, $Bytes.Length) } else { $Bytes.Length }
    return (($Bytes[0..($count - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
}

function New-CentralServerFrame {
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

function Invoke-CentralServerCommand {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][byte[]]$Frame
    )

    $client = [Net.Sockets.TcpClient]::new()
    $client.ReceiveTimeout = 3000
    $client.SendTimeout = 3000

    try {
        $client.Connect([Net.IPAddress]::Loopback, $Port)
        $stream = $client.GetStream()
        $stream.Write($Frame, 0, $Frame.Length)
        $stream.Flush()

        [byte[]]$buffer = [byte[]]::new(8192)
        $count = $stream.Read($buffer, 0, $buffer.Length)
        if ($count -le 0) {
            throw 'MSI CentralServer closed the connection without a response.'
        }

        [byte[]]$response = [byte[]]::new($count)
        [Array]::Copy($buffer, $response, $count)
        return [pscustomobject]@{
            Bytes = $response
            Text  = [Text.Encoding]::UTF8.GetString($response)
        }
    }
    finally {
        $client.Dispose()
    }
}

function Initialize-MsiWmi {
    Add-Type -AssemblyName System.Management

    $scope = [System.Management.ManagementScope]::new('\\.\root\WMI')
    $scope.Connect()
    $searcher = [System.Management.ManagementObjectSearcher]::new(
        $scope,
        [System.Management.ObjectQuery]::new('SELECT * FROM MSI_ACPI')
    )
    $instances = @($searcher.Get())
    $targetObject = $instances |
        Where-Object { [string]$_.Properties['InstanceName'].Value -eq $expectedInstance } |
        Select-Object -First 1

    if ($null -eq $targetObject) {
        throw "Expected MSI_ACPI instance $expectedInstance was not found. No write was attempted."
    }

    $packageClass = [System.Management.ManagementClass]::new(
        $scope,
        [System.Management.ManagementPath]::new('Package_32'),
        $null
    )

    return [pscustomobject]@{
        TargetObject = $targetObject
        PackageClass = $packageClass
    }
}

function Invoke-MsiWmiGet {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('Get_Device', 'Get_AP')][string]$Method,
        [Parameter(Mandatory = $true)][byte]$Selector
    )

    [byte[]]$request = [byte[]]::new(32)
    $request[0] = $Selector
    $package = $Context.PackageClass.CreateInstance()
    $package.SetPropertyValue('Bytes', $request)
    $inParams = $Context.TargetObject.GetMethodParameters($Method)
    $inParams.SetPropertyValue('Data', $package)
    $outParams = $Context.TargetObject.InvokeMethod($Method, $inParams, $null)

    if ($null -eq $outParams -or $null -eq $outParams.Properties['Data'].Value) {
        throw "$Method returned no embedded Data package."
    }

    $outPackage = [System.Management.ManagementBaseObject]$outParams.Properties['Data'].Value
    [byte[]]$response = $outPackage.Properties['Bytes'].Value
    if ($null -eq $response -or $response.Length -lt 1 -or $response[0] -eq 0) {
        throw "$Method returned an invalid or unsuccessful response: $(Format-Bytes -Bytes $response -Maximum 7)"
    }

    return $response
}

function Get-AppliedGpuMode {
    param([Parameter(Mandatory = $true)]$Context)

    [byte[]]$response = Invoke-MsiWmiGet -Context $Context -Method 'Get_Device' -Selector 0x01
    if ($response.Length -lt 2) {
        throw 'Get_Device(1) returned too few bytes to determine the applied GPU mode.'
    }

    $mode = if (($response[1] -band 0x40) -ne 0) { 'Discrete' } else { 'Hybrid' }
    return [pscustomobject]@{
        Mode     = $mode
        Response = $response
    }
}

function Get-LogSnapshot {
    if (-not (Test-Path -LiteralPath $wmiLogPath)) {
        return [pscustomobject]@{ Exists = $false; Length = $null; LastWriteTime = $null }
    }

    $item = Get-Item -LiteralPath $wmiLogPath
    return [pscustomobject]@{
        Exists        = $true
        Length        = $item.Length
        LastWriteTime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
    }
}

try {
    $selectedIndex = switch ($Target) {
        'Hybrid' { 0 }
        'Discrete' { 1 }
        'Integrated' { 2 }
    }
    $switchCommand = "Set;GraphicsSwithc;$selectedIndex"
    $ackCommand = 'Get;VGA_BIOS_Status'
    [byte[]]$switchFrame = New-CentralServerFrame -DestinationId $expectedDestinationId -CommandText $switchCommand
    [byte[]]$ackFrame = New-CentralServerFrame -DestinationId $expectedDestinationId -CommandText $ackCommand

    Write-Output 'MSI CentralServer GPU switch research harness'
    Write-Output ('Requested target      : ' + $Target)
    Write-Output ('Switch command        : ' + $switchCommand)
    Write-Output ('Switch frame          : ' + (Format-Bytes -Bytes $switchFrame))
    Write-Output ('Acknowledge command   : ' + $ackCommand)
    Write-Output ('Acknowledge frame     : ' + (Format-Bytes -Bytes $ackFrame))
    Write-Output ('Registry staging      : GPUswitchCH=' + $selectedIndex + ' (watched by OmApSvcBroker; stages UEFI MsiDCVarData byte 5 bits 0-1)')
    Write-Output 'Side effects          : Registry staging writes UEFI; switch frame reaches firmware D1; acknowledge frame may write BE 02'
    Write-Output 'Shutdown behavior     : this script never shuts down or restarts Windows'

    $bios = Get-ItemProperty -LiteralPath $biosKey
    Write-Output ('Computer manufacturer : ' + [string]$bios.SystemManufacturer)
    Write-Output ('Computer model        : ' + [string]$bios.SystemProductName)
    if ([string]$bios.SystemManufacturer -notmatch 'Micro-Star|MSI' -or [string]$bios.SystemProductName -ne $expectedModel) {
        throw "Hardware identity does not match the validated MSI $expectedModel. No network request was sent."
    }

    $sdk = Get-ItemProperty -LiteralPath $sdkKey
    $baseModule = Get-ItemProperty -LiteralPath $baseModuleKey
    $generalSetting = Get-ItemProperty -LiteralPath $generalSettingKey
    $port = [int]$sdk.'Server Port'
    $destinationId = [int]$baseModule.ID
    $serverPid = [int]$sdk.PID

    Write-Output ('Registry server port  : ' + $port)
    Write-Output ('Registry destination  : ' + $destinationId)
    Write-Output ('Registry server PID   : ' + $serverPid)
    Write-Output ('New switch support    : ' + [int]$generalSetting.GPUswitchSP)
    Write-Output ('Current UEFI mode     : ' + [int]$generalSetting.GPUswitchST + ' (0=Hybrid, 1=Discrete, 2=Integrated)')
    Write-Output ('Integrated support    : ' + [int]$generalSetting.GPUswitchUMA)
    Write-Output ('Discrete support      : ' + [int]$generalSetting.GPUswitchDiscrete)
    if ($port -ne $expectedPort) {
        throw "Unexpected MSI CentralServer port $port. No network request was sent."
    }
    if ($destinationId -ne $expectedDestinationId) {
        throw "Unexpected Base Module component ID $destinationId. No network request was sent."
    }
    if ([int]$generalSetting.GPUswitchSP -ne 1) {
        throw 'MSI new GPU switch support flag is not 1. No write was attempted.'
    }
    if ([int]$generalSetting.GPUswitchST -notin 0, 1, 2) {
        throw 'MSI UEFI-derived current GPU mode is outside 0..2. No write was attempted.'
    }
    if ($Target -eq 'Integrated' -and [int]$generalSetting.GPUswitchUMA -ne 1) {
        throw 'Integrated/UMA mode is not supported according to GPUswitchUMA. No write was attempted.'
    }
    if ($Target -eq 'Discrete' -and [int]$generalSetting.GPUswitchDiscrete -ne 1) {
        throw 'Discrete mode is not supported according to GPUswitchDiscrete. No write was attempted.'
    }

    $serverProcess = Get-Process -Id $serverPid -ErrorAction Stop
    if ($serverProcess.ProcessName -ne 'MSI.CentralServer') {
        throw "Registry PID $serverPid belongs to $($serverProcess.ProcessName), not MSI.CentralServer. No network request was sent."
    }
    $broker = @(Get-Process -Name 'OmApSvcBroker' -ErrorAction SilentlyContinue)
    if ($broker.Count -ne 1) {
        throw 'Exactly one OmApSvcBroker process must be running so the official GPUswitchCH watcher can stage UEFI. No write was attempted.'
    }
    Write-Output ('OmApSvcBroker PID      : ' + $broker[0].Id)

    if (-not $ConfirmRegistryAndFirmwareWrite) {
        Write-Output 'Execution state       : DRY RUN; no TCP connection, WMI call, registry write, or firmware write was made'
        exit 0
    }

    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required for the authoritative WMI precheck. No network request was sent.'
    }

    $context = Initialize-MsiWmi
    $beforeMode = Get-AppliedGpuMode -Context $context
    [byte[]]$apBefore = Invoke-MsiWmiGet -Context $context -Method 'Get_AP' -Selector 0x00
    if ($apBefore.Length -lt 3) {
        throw 'Get_AP(0) returned too few bytes. No network request was sent.'
    }

    $currentMode = @('Hybrid', 'Discrete', 'Integrated')[[int]$generalSetting.GPUswitchST]
    Write-Output ('Applied mode before   : ' + $currentMode + ' (UEFI-derived GPUswitchST)')
    Write-Output ('Legacy WMI mode       : ' + $beforeMode.Mode + ' (cannot distinguish Hybrid from Integrated)')
    Write-Output ('Get_Device before     : ' + (Format-Bytes -Bytes $beforeMode.Response -Maximum 7))
    Write-Output ('Get_AP before         : ' + (Format-Bytes -Bytes $apBefore -Maximum 7))
    if (($apBefore[2] -band 0x02) -ne 0) {
        throw 'Get_AP(0).Data[1].bit1 is already set. Refusing to overlap an existing pending request.'
    }
    if ($currentMode -eq 'Hybrid' -and $beforeMode.Mode -ne 'Hybrid') {
        throw 'GPUswitchST says Hybrid but Get_Device(1) says Discrete. Refusing to write on inconsistent status.'
    }
    if ($currentMode -eq 'Discrete' -and $beforeMode.Mode -ne 'Discrete') {
        throw 'GPUswitchST says Discrete but Get_Device(1) does not. Refusing to write on inconsistent status.'
    }
    if ($currentMode -eq $Target) {
        Write-Output 'Current applied mode already matches the requested target. No network request was sent.'
        exit 0
    }

    $logBefore = Get-LogSnapshot
    Write-Output ('WMI log before        : exists={0}; length={1}; lastWrite={2}' -f $logBefore.Exists, $logBefore.Length, $logBefore.LastWriteTime)

    Write-Output ('WRITE registry at     : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
    Set-ItemProperty -LiteralPath $generalSettingKey -Name 'GPUswitchCH' -Value ([int]$selectedIndex)
    $stagedValue = [int](Get-ItemPropertyValue -LiteralPath $generalSettingKey -Name 'GPUswitchCH')
    Write-Output ('GPUswitchCH after     : ' + $stagedValue)
    if ($stagedValue -ne $selectedIndex) {
        throw 'GPUswitchCH did not retain the requested staging value. The switch frame was not sent.'
    }
    $registryStaged = $true

    Write-Output ('SEND switch at        : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
    $switchResponse = Invoke-CentralServerCommand -Port $port -Frame $switchFrame
    Write-Output ('Switch response hex   : ' + (Format-Bytes -Bytes $switchResponse.Bytes))
    Write-Output ('Switch response text  : ' + $switchResponse.Text)
    if (-not $switchResponse.Text.StartsWith('Set;GraphicsSwithc;', [StringComparison]::Ordinal)) {
        throw 'CentralServer returned an unexpected switch response. The acknowledge command was not sent.'
    }

    Write-Output 'Post-switch delay     : 2000 ms (matches MSI Center UI)'
    Start-Sleep -Milliseconds 2000
    [byte[]]$apAfterSwitch = Invoke-MsiWmiGet -Context $context -Method 'Get_AP' -Selector 0x00
    Write-Output ('Get_AP after switch   : ' + (Format-Bytes -Bytes $apAfterSwitch -Maximum 7))
    if ($apAfterSwitch.Length -lt 3 -or (($apAfterSwitch[2] -band 0x02) -eq 0)) {
        throw 'The D1 acceptance bit was not set after two seconds. The acknowledge command was not sent.'
    }

    Write-Output ('SEND acknowledge at   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
    $ackResponse = Invoke-CentralServerCommand -Port $port -Frame $ackFrame
    Write-Output ('Acknowledge resp hex  : ' + (Format-Bytes -Bytes $ackResponse.Bytes))
    Write-Output ('Acknowledge resp text : ' + $ackResponse.Text)
    if ($ackResponse.Text -ne 'Get;VGA_BIOS_Status;1') {
        throw 'CentralServer did not return the expected VGA_BIOS_Status success response.'
    }

    [byte[]]$apFinal = Invoke-MsiWmiGet -Context $context -Method 'Get_AP' -Selector 0x00
    $immediateMode = Get-AppliedGpuMode -Context $context
    $logAfter = Get-LogSnapshot
    Write-Output ('Get_AP final          : ' + (Format-Bytes -Bytes $apFinal -Maximum 7))
    Write-Output ('Immediate legacy mode : ' + $immediateMode.Mode + ' (application is only judged after a user-initiated restart)')
    Write-Output ('WMI log after         : exists={0}; length={1}; lastWrite={2}' -f $logAfter.Exists, $logAfter.Length, $logAfter.LastWriteTime)
    Write-Output 'Request accepted through CentralServer. Save this output, restart Windows manually, then run the read-only status tool.'
    exit 0
}
catch {
    $ex = $_.Exception
    $detail = $ex
    while ($null -ne $detail.InnerException) {
        $detail = $detail.InnerException
    }

    [Console]::Error.WriteLine('CentralServer GPU switch harness stopped: ' + $ex.Message)
    if ($registryStaged) {
        [Console]::Error.WriteLine('WARNING        : GPUswitchCH was already changed and OmApSvcBroker may already have staged the UEFI target. Do not retry automatically.')
    }
    [Console]::Error.WriteLine('Exception type : ' + $detail.GetType().FullName)
    [Console]::Error.WriteLine('HRESULT        : ' + (Format-HResult -Value $detail.HResult))
    if ($detail -is [System.Management.ManagementException]) {
        [Console]::Error.WriteLine('WMI status     : ' + $detail.ErrorCode)
    }
    exit 1
}
