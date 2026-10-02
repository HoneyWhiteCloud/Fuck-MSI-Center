# Read-only MSI MUX status probe for this investigation.
# It invokes only root/WMI:MSI_ACPI.Get_Device with selector 0x01.
# It also reads the MSI broker's UEFI-derived GPUswitchST value so that
# Integrated can be distinguished from Hybrid. It deliberately does not load MSI assemblies, write the registry,
# call VGA_BIOS_Status, or invoke any Set_* method.

#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-HResult {
    param([int]$Value)
    return ('0x{0:X8}' -f $Value)
}

try {
    Add-Type -AssemblyName System.Management

    $scope = [System.Management.ManagementScope]::new('\\.\root\WMI')
    $scope.Connect()

    $query = [System.Management.ObjectQuery]::new('SELECT * FROM MSI_ACPI')
    $searcher = [System.Management.ManagementObjectSearcher]::new($scope, $query)
    $instances = @($searcher.Get())

    if ($instances.Count -eq 0) {
        throw 'No MSI_ACPI instance was returned by root/WMI.'
    }

    $target = $instances |
        Where-Object { [string]$_.Properties['InstanceName'].Value -eq 'ACPI\PNP0C14\0_0' } |
        Select-Object -First 1

    if ($null -eq $target) {
        $names = $instances | ForEach-Object { [string]$_.Properties['InstanceName'].Value }
        throw ('Expected MSI_ACPI instance ACPI\PNP0C14\0_0 was not found. Returned: ' + ($names -join ', '))
    }

    $packageClass = [System.Management.ManagementClass]::new(
        $scope,
        [System.Management.ManagementPath]::new('Package_32'),
        $null
    )
    $package = $packageClass.CreateInstance()

    [byte[]]$request = [byte[]]::new(32)
    $request[0] = 0x01
    $package.SetPropertyValue('Bytes', $request)

    $inParams = $target.GetMethodParameters('Get_Device')
    $inParams.SetPropertyValue('Data', $package)
    $outParams = $target.InvokeMethod('Get_Device', $inParams, $null)

    if ($null -eq $outParams -or $null -eq $outParams.Properties['Data'].Value) {
        throw 'Get_Device returned no Data package.'
    }

    $outPackage = [System.Management.ManagementBaseObject]$outParams.Properties['Data'].Value
    [byte[]]$response = $outPackage.Properties['Bytes'].Value

    if ($null -eq $response -or $response.Length -lt 2) {
        throw "Get_Device returned an invalid byte array (length $($response.Length))."
    }

    [byte]$flag = $response[0]
    [byte]$data0 = $response[1]
    $previewLength = [Math]::Min(7, $response.Length)
    $preview = ($response[0..($previewLength - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '

    Write-Output 'WMI method     : root/WMI:MSI_ACPI.Get_Device'
    Write-Output 'Request selector: 0x01'
    Write-Output ('Response[0..{0}]: {1}' -f ($previewLength - 1), $preview)
    Write-Output ('Flag           : 0x{0:X2}' -f $flag)
    Write-Output ('Data[0]        : 0x{0:X2}' -f $data0)

    if ($flag -eq 0) {
        Write-Error 'Firmware returned Flag=0. GPU mode is unknown; refusing to infer a result.'
        exit 4
    }

    $legacyMode = if (($data0 -band 0x40) -ne 0) { 'Discrete' } else { 'Hybrid-or-Integrated' }
    Write-Output ('Legacy WMI mode : ' + $legacyMode)

    $generalSettingKey = 'HKLM:\SOFTWARE\WOW6432Node\MSI\MSI Center\Component\Base Module\GeneralSetting'
    $generalSetting = Get-ItemProperty -LiteralPath $generalSettingKey
    $newSwitchSupport = [int]$generalSetting.GPUswitchSP
    $currentStatus = [int]$generalSetting.GPUswitchST
    Write-Output ('New switch support: ' + $newSwitchSupport)
    Write-Output ('GPUswitchST     : ' + $currentStatus + ' (UEFI-derived by OmApSvcBroker at startup)')

    if ($newSwitchSupport -ne 1 -or $currentStatus -notin 0, 1, 2) {
        Write-Error 'The three-mode MSI broker status is unavailable or malformed; refusing to infer Hybrid versus Integrated.'
        exit 5
    }

    $broker = @(Get-Process -Name 'OmApSvcBroker' -ErrorAction SilentlyContinue)
    if ($broker.Count -ne 1) {
        Write-Error 'OmApSvcBroker is not running exactly once; GPUswitchST freshness cannot be validated.'
        exit 6
    }

    $mode = @('MSHybrid Graphics Mode', 'Discrete Graphics Mode', 'Integrated Graphics Mode')[$currentStatus]
    if ($currentStatus -eq 0 -and ($data0 -band 0x40) -ne 0) {
        Write-Error 'GPUswitchST says Hybrid but Get_Device(1) says Discrete; status sources are inconsistent.'
        exit 7
    }
    if ($currentStatus -eq 1 -and ($data0 -band 0x40) -eq 0) {
        Write-Error 'GPUswitchST says Discrete but Get_Device(1) does not; status sources are inconsistent.'
        exit 7
    }

    Write-Output ('GPU mode        : ' + $mode)
    exit 0
}
catch {
    $ex = $_.Exception
    $detail = $ex
    while ($null -ne $detail.InnerException) {
        $detail = $detail.InnerException
    }

    [Console]::Error.WriteLine('Read-only MSI_ACPI.Get_Device query failed: ' + $ex.Message)
    [Console]::Error.WriteLine('Exception type : ' + $detail.GetType().FullName)
    [Console]::Error.WriteLine('HRESULT        : ' + (Format-HResult -Value $detail.HResult))

    if ($detail -is [System.Management.ManagementException]) {
        [Console]::Error.WriteLine('WMI status     : ' + $detail.ErrorCode)
    }

    exit 1
}
