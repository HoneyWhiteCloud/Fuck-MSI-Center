# Read-only probe for the Get_AP(0) input used by MSI's GPU switch backend.
# This script never invokes Set_Data or any other Set_* method.

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

    $searcher = [System.Management.ManagementObjectSearcher]::new(
        $scope,
        [System.Management.ObjectQuery]::new('SELECT * FROM MSI_ACPI')
    )
    $instances = @($searcher.Get())
    $target = $instances |
        Where-Object { [string]$_.Properties['InstanceName'].Value -eq 'ACPI\PNP0C14\0_0' } |
        Select-Object -First 1

    if ($null -eq $target) {
        throw 'Expected MSI_ACPI instance ACPI\PNP0C14\0_0 was not found.'
    }

    $packageClass = [System.Management.ManagementClass]::new(
        $scope,
        [System.Management.ManagementPath]::new('Package_32'),
        $null
    )
    $package = $packageClass.CreateInstance()
    [byte[]]$request = [byte[]]::new(32)
    $request[0] = 0x00
    $package.SetPropertyValue('Bytes', $request)

    $inParams = $target.GetMethodParameters('Get_AP')
    $inParams.SetPropertyValue('Data', $package)
    $outParams = $target.InvokeMethod('Get_AP', $inParams, $null)
    $outPackage = [System.Management.ManagementBaseObject]$outParams.Properties['Data'].Value
    [byte[]]$response = $outPackage.Properties['Bytes'].Value

    if ($null -eq $response -or $response.Length -lt 3) {
        throw "Get_AP returned an invalid byte array (length $($response.Length))."
    }

    $previewLength = [Math]::Min(7, $response.Length)
    $preview = ($response[0..($previewLength - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    [byte]$flag = $response[0]
    [byte]$data1 = $response[2]
    [byte]$msiPayload = (($data1 -band 0xFC) -bor 0x01)

    Write-Output 'WMI method          : root/WMI:MSI_ACPI.Get_AP'
    Write-Output 'Request selector    : 0x00'
    Write-Output ('Response[0..{0}]     : {1}' -f ($previewLength - 1), $preview)
    Write-Output ('Flag                : 0x{0:X2}' -f $flag)
    Write-Output ('Data[1]             : 0x{0:X2}' -f $data1)
    Write-Output ('MSI-derived payload : 0x{0:X2} (calculated only; NOT WRITTEN)' -f $msiPayload)

    if ($flag -eq 0) {
        [Console]::Error.WriteLine('Firmware returned Flag=0. State is unknown.')
        exit 4
    }

    exit 0
}
catch {
    $ex = $_.Exception
    $detail = $ex
    while ($null -ne $detail.InnerException) {
        $detail = $detail.InnerException
    }

    [Console]::Error.WriteLine('Read-only MSI_ACPI.Get_AP query failed: ' + $ex.Message)
    [Console]::Error.WriteLine('Exception type : ' + $detail.GetType().FullName)
    [Console]::Error.WriteLine('HRESULT        : ' + (Format-HResult -Value $detail.HResult))
    if ($detail -is [System.Management.ManagementException]) {
        [Console]::Error.WriteLine('WMI status     : ' + $detail.ErrorCode)
    }
    exit 1
}
