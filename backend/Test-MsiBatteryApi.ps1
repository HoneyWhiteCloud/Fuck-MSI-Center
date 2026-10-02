# Contract tests mock all hardware access; optional live checks perform only Get_Data.
#requires -Version 5.1
[CmdletBinding()]
param([switch]$IncludeLiveReadOnly, [switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'MsiDirectHardwareApi.psd1'
Import-Module $modulePath -Force
$module = Get-Module MsiDirectHardwareApi

$contract = try {
    & $module {
        function script:Assert-MsiDirectHardwareIdentity { [pscustomobject]@{ Manufacturer = 'MSI'; Model = 'Sword 16 HX B14VGKG' } }
        function script:Test-MsiDirectAdministrator { $script:batteryTestAdmin }
        function script:Enter-MsiDirectAcpiMutex { $script:batteryTestLockEntries++; [pscustomobject]@{ TestLock = $true } }
        function script:Exit-MsiDirectAcpiMutex { param($Mutex) $script:batteryTestLockExits++ }
        function script:New-MsiDirectAcpiContext { [pscustomobject]@{ TestContext = $true } }
        function script:Get-MsiBatteryPolicyInfo { [pscustomobject]@{ AIChargerEnabled = $false; Warning = 'Test only' } }
        function script:Invoke-MsiDirectAcpiGet {
            param($Context, $Method, $Selector)
            if ($Method -ne 'Get_Data' -or $Selector -ne 0xD7) { throw 'Unexpected read primitive.' }
            $script:batteryTestReadCalls++
            if ($script:batteryTestResponses.Count -eq 0) { throw 'Unexpected extra hardware read.' }
            [byte[]]$bytes = $script:batteryTestResponses.Dequeue()
            [pscustomobject]@{ Flag = $bytes[0]; Response = $bytes; ResponseHex = Format-MsiDirectBytes $bytes; ReturnValue = $script:batteryTestReadReturn }
        }
        function script:Invoke-MsiDirectSetData {
            param($Context, $Address, $Value)
            if ($Address -ne 0xD7) { throw 'Unexpected write address.' }
            $script:batteryTestWriteCalls++
            $script:batteryTestPayload = [int]$Value
            if ($script:batteryTestWriteThrow) { throw 'Simulated WMI transport failure.' }
            [pscustomobject]@{ Flag = $script:batteryTestWriteFlag; ResponseHex = '01'; ReturnValue = $true }
        }
        function Reset-BatteryFixture {
            $script:batteryTestResponses = [Collections.Generic.Queue[object]]::new()
            $script:batteryTestAdmin = $true
            $script:batteryTestReadReturn = $true
            $script:batteryTestWriteFlag = 1
            $script:batteryTestWriteThrow = $false
            $script:batteryTestReadCalls = 0
            $script:batteryTestWriteCalls = 0
            $script:batteryTestPayload = -1
            $script:batteryTestLockEntries = 0
            $script:batteryTestLockExits = 0
        }
        function Assert-BatteryTest { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
        $cases = 0
        foreach ($highBit in 0, 128) {
            foreach ($current in 60, 80, 100) {
                foreach ($target in 60, 80, 100) {
                    Reset-BatteryFixture
                    $raw = $highBit -bor $current
                    $script:batteryTestResponses.Enqueue([byte[]]@(1, $raw))
                    $plan = Get-MsiDirectBatteryPlan -ChargeLimitPercent $target
                    $expected = $highBit -bor $target
                    Assert-BatteryTest ($plan.PlannedRawValue -eq ('0x{0:X2}' -f $expected)) 'Plan did not preserve bit7.'
                    Assert-BatteryTest (-not $plan.WritesOnPlan -and $script:batteryTestWriteCalls -eq 0) 'Plan performed a write.'
                    Assert-BatteryTest ($script:batteryTestLockEntries -eq $script:batteryTestLockExits) 'Plan did not release its mutex.'
                    Reset-BatteryFixture
                    $script:batteryTestResponses.Enqueue([byte[]]@(1, $raw))
                    if ($current -ne $target) { $script:batteryTestResponses.Enqueue([byte[]]@(1, $expected)) }
                    $set = Set-MsiDirectBatteryLimit -ChargeLimitPercent $target -ConfirmBatteryChange
                    $expectedWrites = if ($current -eq $target) { 0 } else { 1 }
                    Assert-BatteryTest ($set.Success -and $set.Verified -and $set.ChargeLimitPercent -eq $target) 'Set did not verify the target.'
                    Assert-BatteryTest ($script:batteryTestWriteCalls -eq $expectedWrites) 'Set exceeded one write or wrote an already-applied value.'
                    if ($expectedWrites) { Assert-BatteryTest ($script:batteryTestPayload -eq $expected) 'Set corrupted bit7.' }
                    Assert-BatteryTest ($script:batteryTestLockEntries -eq 1 -and $script:batteryTestLockExits -eq 1) 'Set did not hold one mutex for the complete transaction.'
                    $cases++
                }
            }
        }
        foreach ($invalidResponse in @([byte[]]@(0, 100), [byte[]]@(2, 100), [byte[]]@(1), [byte[]]@(1, 95))) {
            Reset-BatteryFixture
            $script:batteryTestResponses.Enqueue($invalidResponse)
            $set = Set-MsiDirectBatteryLimit -ChargeLimitPercent 60 -ConfirmBatteryChange
            Assert-BatteryTest (-not $set.Success -and -not $set.RequestSent -and $script:batteryTestWriteCalls -eq 0) 'Malformed/unknown state allowed a write.'
            Assert-BatteryTest ($script:batteryTestLockExits -eq 1) 'Failed read did not release the mutex.'
        }
        foreach ($failure in 'FalseReturn', 'RejectedWrite', 'ThrownWrite', 'MismatchedReadBack') {
            Reset-BatteryFixture
            $script:batteryTestResponses.Enqueue([byte[]]@(1, 100))
            switch ($failure) {
                FalseReturn { $script:batteryTestReadReturn = $false }
                RejectedWrite { $script:batteryTestWriteFlag = 0 }
                ThrownWrite { $script:batteryTestWriteThrow = $true }
                MismatchedReadBack { $script:batteryTestResponses.Enqueue([byte[]]@(1, 100)) }
            }
            $set = Set-MsiDirectBatteryLimit -ChargeLimitPercent 60 -ConfirmBatteryChange
            $expectedWrites = if ($failure -eq 'FalseReturn') { 0 } else { 1 }
            Assert-BatteryTest (-not $set.Success -and -not $set.Verified -and -not $set.AutomaticRetry) 'Failure was reported as verified.'
            Assert-BatteryTest ($script:batteryTestWriteCalls -eq $expectedWrites) 'Failure caused a retry.'
            Assert-BatteryTest ($set.RequestSent -eq [bool]$expectedWrites) 'Failure lost write-attempt metadata.'
            Assert-BatteryTest ($script:batteryTestLockExits -eq 1) 'Failure did not release its mutex.'
        }
        foreach ($guard in 'Confirmation', 'Administrator', 'InvalidLimit') {
            Reset-BatteryFixture
            $blocked = $false
            try {
                switch ($guard) {
                    Confirmation { Set-MsiDirectBatteryLimit -ChargeLimitPercent 60 -ConfirmBatteryChange:$false }
                    Administrator { $script:batteryTestAdmin = $false; Set-MsiDirectBatteryLimit -ChargeLimitPercent 60 -ConfirmBatteryChange }
                    InvalidLimit { Set-MsiDirectBatteryLimit -ChargeLimitPercent 95 -ConfirmBatteryChange }
                }
            } catch { $blocked = $true }
            Assert-BatteryTest ($blocked -and $script:batteryTestReadCalls -eq 0 -and $script:batteryTestWriteCalls -eq 0) "$guard guard did not stop before hardware access."
        }
        [pscustomobject]@{ Success = $true; PresetTransitionCases = $cases; Bit7Preserved = $true; MalformedStatesBlocked = $true; FailureNeverRetries = $true; ConfirmationAndAdminGuardsPassed = $true; HardwareAccessMocked = $true }
    }
} finally { Import-Module $modulePath -Force }

$live = $null
if ($IncludeLiveReadOnly) {
    $module = Get-Module MsiDirectHardwareApi
    $live = try {
        & $module {
            # Fail closed if a future regression attempts any live Set_Data.
            function script:Invoke-MsiDirectSetData { throw 'Live Set_Data is forbidden in this read-only test.' }
            $before = Get-MsiDirectBatteryState
            $plans = @(foreach ($limit in 60, 80, 100) { Get-MsiDirectBatteryPlan -ChargeLimitPercent $limit })
            $after = Get-MsiDirectBatteryState
            if ($before.RawValue -ne $after.RawValue) { throw 'Hardware charge limit changed during read-only checks.' }
            foreach ($plan in $plans) { if (-not $plan.Success -or $plan.WritesOnPlan) { throw 'A live Plan was not read-only.' } }
            [pscustomobject]@{ Success = $true; State = $after; Plans = $plans; HardwareStateUnchanged = $true; LiveSetDataCalls = 0 }
        }
    } finally { Import-Module $modulePath -Force }
}

$result = [pscustomobject]@{ Success = $true; Contract = $contract; LiveReadOnly = $live; LiveSetDataCalls = 0 }
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result | Format-List }
