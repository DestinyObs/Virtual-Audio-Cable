#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the Virtual Audio Cable driver and, optionally, the test setup.

.DESCRIPTION
    Run in an elevated PowerShell window:

        powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1

    Removes the virtual device and the driver package, then offers to remove
    the test certificate and to turn test signing back off. Asks before each
    change. Use -Yes to answer yes to every prompt.
#>
[CmdletBinding()]
param(
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$HardwareId  = 'ROOT\VirtualAudioDriver'
$InfName     = 'virtualaudiodriver.inf'
$CertSubject = 'CN=Virtual Audio Cable Test Signing'

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   OK: $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "   $Text" }

function Confirm-Action([string]$Question) {
    if ($Yes) { return $true }
    $answer = Read-Host "   $Question [y/N]"
    return ($answer -match '^(y|yes)$')
}

# ---------------------------------------------------------------------------
Write-Step 'Removing the virtual device'
$devices = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.HardwareID -contains $HardwareId })

if ($devices.Count -eq 0) {
    Write-Ok 'No Virtual Audio Cable device found.'
} elseif (Confirm-Action "Remove $($devices.Count) Virtual Audio Cable device(s)?") {
    foreach ($device in $devices) {
        & pnputil /remove-device $device.PNPDeviceID
        if ($LASTEXITCODE -ne 0) { Write-Note "Could not remove $($device.PNPDeviceID) (exit $LASTEXITCODE)." }
        else { Write-Ok "Removed $($device.PNPDeviceID)." }
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Removing the driver package'
$published = @()
$current = $null
foreach ($line in (& pnputil /enum-drivers)) {
    if ($line -match ':\s*(oem\d+\.inf)\s*$') { $current = $Matches[1] }
    elseif ($current -and $line -match ':\s*(\S+\.inf)\s*$' -and $Matches[1] -ieq $InfName) {
        $published += $current
        $current = $null
    }
}

if ($published.Count -eq 0) {
    Write-Ok 'No driver package found in the driver store.'
} elseif (Confirm-Action "Delete driver package(s) $($published -join ', ')?") {
    foreach ($oem in $published) {
        & pnputil /delete-driver $oem /uninstall /force
        if ($LASTEXITCODE -ne 0) { Write-Note "Could not delete $oem (exit $LASTEXITCODE)." }
        else { Write-Ok "Deleted $oem." }
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Removing the test certificate'
$certs = @(
    Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher |
        Where-Object { $_.Subject -eq $CertSubject }
)

if ($certs.Count -eq 0) {
    Write-Ok 'Test certificate not present.'
} elseif (Confirm-Action "Remove the test certificate from $($certs.Count) store location(s)?") {
    $certs | Remove-Item
    Write-Ok 'Test certificate removed.'
}

# ---------------------------------------------------------------------------
Write-Step 'Test signing'
Write-Note 'Leave test signing on if other test-signed drivers are in use on this PC.'
if (Confirm-Action 'Turn test signing off (takes effect after reboot)?') {
    & bcdedit /set testsigning off
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Test signing will be off after the next reboot. Secure Boot can then be turned back on in firmware.'
    } else {
        Write-Note "bcdedit failed (exit $LASTEXITCODE)."
    }
}

Write-Host "`nDone." -ForegroundColor Green
