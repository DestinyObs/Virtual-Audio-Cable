#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the test-signed Virtual Audio Cable driver.

.DESCRIPTION
    Run from the extracted package folder in an elevated PowerShell window:

        powershell -ExecutionPolicy Bypass -File .\Install.ps1

    The script checks prerequisites and asks before every change:
      1. Secure Boot must be off (test-signed drivers cannot load with it on).
      2. Test signing must be on (enabling it needs one reboot, then run again).
      3. The package's test certificate is trusted on this machine.
      4. The driver package is added and the virtual device is created.

    Use -Yes to answer yes to every prompt.
#>
[CmdletBinding()]
param(
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$HardwareId = 'ROOT\VirtualAudioDriver'
$MediaClass = 'MEDIA'
$MediaGuid  = [Guid]'4d36e96c-e325-11ce-bfc1-08002be10318'

$PackageDir = $PSScriptRoot
$InfPath    = Join-Path $PackageDir 'driver\VirtualAudioDriver.inf'
$CertPath   = Join-Path $PackageDir 'VirtualAudioCable-TestCert.cer'

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   OK: $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "   $Text" }

function Confirm-Action([string]$Question) {
    if ($Yes) { return $true }
    $answer = Read-Host "   $Question [y/N]"
    return ($answer -match '^(y|yes)$')
}

function Stop-Install([string]$Text) {
    Write-Host "`n   STOPPED: $Text" -ForegroundColor Yellow
    exit 1
}

function Get-TestSigningEnabled {
    $output = & bcdedit /enum '{current}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return [bool]($output | Select-String -Pattern '^\s*testsigning\s+Yes' -Quiet)
}

function Get-SecureBootState {
    try {
        if (Confirm-SecureBootUEFI) { return 'On' } else { return 'Off' }
    } catch [System.PlatformNotSupportedException] {
        return 'NotSupported'
    } catch {
        return 'Unknown'
    }
}

function Get-CableDevices {
    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.HardwareID -contains $HardwareId }
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class RootDeviceInstaller
{
    const int DICD_GENERATE_ID   = 0x1;
    const int DIF_REGISTERDEVICE = 0x19;
    const int SPDRP_HARDWAREID   = 0x1;
    const int INSTALLFLAG_FORCE  = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA
    {
        public int    cbSize;
        public Guid   ClassGuid;
        public int    DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiCreateDeviceInfoW(IntPtr deviceInfoSet, string deviceName,
        ref Guid classGuid, string deviceDescription, IntPtr hwndParent, int creationFlags,
        ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr deviceInfoSet,
        ref SP_DEVINFO_DATA deviceInfoData, int property, byte[] propertyBuffer, int propertyBufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiCallClassInstaller(int installFunction, IntPtr deviceInfoSet,
        ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwndParent, string hardwareId,
        string fullInfPath, int installFlags, out bool rebootRequired);

    // Creates a root-enumerated device node and installs the driver on it,
    // equivalent to "devcon install <inf> <hwid>". Returns true if a reboot is needed.
    public static bool Install(string className, Guid classGuid, string hardwareId, string infPath)
    {
        IntPtr set = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList");

        try
        {
            var data = new SP_DEVINFO_DATA();
            data.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));

            if (!SetupDiCreateDeviceInfoW(set, className, ref classGuid, null, IntPtr.Zero, DICD_GENERATE_ID, ref data))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfo");

            byte[] ids = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryPropertyW(set, ref data, SPDRP_HARDWAREID, ids, ids.Length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiSetDeviceRegistryProperty");

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, ref data))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCallClassInstaller(DIF_REGISTERDEVICE)");
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(set);
        }

        bool reboot;
        if (!UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareId, infPath, INSTALLFLAG_FORCE, out reboot))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateDriverForPlugAndPlayDevices");

        return reboot;
    }
}
'@

# ---------------------------------------------------------------------------
Write-Step 'Checking package'
if (-not [Environment]::Is64BitOperatingSystem) { Stop-Install 'This package is for 64-bit Windows only.' }
foreach ($file in @($InfPath, (Join-Path $PackageDir 'driver\VirtualAudioDriver.sys'), $CertPath)) {
    if (-not (Test-Path $file)) { Stop-Install "Missing file: $file" }
}
if (-not (Get-ChildItem (Join-Path $PackageDir 'driver') -Filter *.cat)) { Stop-Install 'Missing driver catalog (.cat).' }
Write-Ok 'All package files present.'

# ---------------------------------------------------------------------------
Write-Step 'Checking Secure Boot'
$secureBoot = Get-SecureBootState
switch ($secureBoot) {
    'On' {
        Write-Note 'Secure Boot is ON. Windows will not load test-signed drivers while it is on.'
        Write-Note 'Turn it off in the PC firmware (BIOS/UEFI) settings, usually under Boot or Security,'
        Write-Note 'then run this script again.'
        Stop-Install 'Secure Boot must be turned off first.'
    }
    'Off'          { Write-Ok 'Secure Boot is off.' }
    'NotSupported' { Write-Ok 'Legacy BIOS boot, Secure Boot not applicable.' }
    default        { Write-Note 'Could not read Secure Boot state. Continuing; if the device shows Code 52 later, check it in firmware settings.' }
}

# ---------------------------------------------------------------------------
Write-Step 'Checking test signing'
if (Get-TestSigningEnabled) {
    Write-Ok 'Test signing is on.'
} else {
    Write-Note 'Test signing is OFF. It must be on for this driver to load.'
    Write-Note 'Turning it on shows a "Test Mode" watermark on the desktop and needs a reboot.'
    if (-not (Confirm-Action 'Turn test signing on now?')) { Stop-Install 'Test signing was not enabled.' }

    & bcdedit /set testsigning on
    if ($LASTEXITCODE -ne 0) { Stop-Install 'bcdedit failed. If Secure Boot is on, turn it off first.' }

    Write-Ok 'Test signing enabled.'
    Write-Host "`n   Reboot the PC, then run this script again to finish the install." -ForegroundColor Yellow
    if (Confirm-Action 'Reboot now?') { Restart-Computer -Force }
    exit 0
}

# ---------------------------------------------------------------------------
Write-Step 'Trusting the package test certificate'
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CertPath
$inRoot      = Test-Path "Cert:\LocalMachine\Root\$($cert.Thumbprint)"
$inPublisher = Test-Path "Cert:\LocalMachine\TrustedPublisher\$($cert.Thumbprint)"

if ($inRoot -and $inPublisher) {
    Write-Ok "Certificate already trusted ($($cert.Subject))."
} else {
    Write-Note "Certificate: $($cert.Subject)"
    Write-Note "Thumbprint:  $($cert.Thumbprint)"
    Write-Note 'It will be added to Trusted Root and Trusted Publishers on this machine only.'
    if (-not (Confirm-Action 'Trust this certificate?')) { Stop-Install 'Certificate not trusted.' }

    if (-not $inRoot)      { Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null }
    if (-not $inPublisher) { Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null }
    Write-Ok 'Certificate trusted.'
}

# ---------------------------------------------------------------------------
Write-Step 'Installing the driver'
$existing = @(Get-CableDevices)

if ($existing.Count -gt 0) {
    Write-Note "Virtual Audio Cable device already exists ($($existing.Count)). The driver will be updated on it."
} else {
    Write-Note 'A new virtual audio device will be created: "Virtual Cable Output" and "Virtual Cable Input".'
}
if (-not (Confirm-Action 'Install the driver now?')) { Stop-Install 'Driver not installed.' }

& pnputil /add-driver $InfPath /install
# 0 = success, 3010 = success but reboot needed,
# 259 = package added but no device matched yet (expected on a first install).
if (@(0, 259, 3010) -notcontains $LASTEXITCODE) { Stop-Install "pnputil failed with exit code $LASTEXITCODE." }

$rebootNeeded = ($LASTEXITCODE -eq 3010)

if ($existing.Count -eq 0) {
    $rebootNeeded = [RootDeviceInstaller]::Install($MediaClass, $MediaGuid, $HardwareId, $InfPath) -or $rebootNeeded
}

# ---------------------------------------------------------------------------
Write-Step 'Verifying'
Start-Sleep -Seconds 2
$devices = @(Get-CableDevices)
if ($devices.Count -eq 0) { Stop-Install 'Device was not created. Check Device Manager under "Sound, video and game controllers".' }

$failed = $false
foreach ($device in $devices) {
    $code = $device.ConfigManagerErrorCode
    if ($code -eq 0) {
        Write-Ok "$($device.Name) is working."
    } elseif ($code -eq 52) {
        $failed = $true
        Write-Note "$($device.Name): Code 52 (signature not trusted)."
        Write-Note 'Check that Secure Boot is off and test signing is on, then reboot.'
    } else {
        $failed = $true
        Write-Note "$($device.Name): device error code $code."
    }
}

if ($rebootNeeded) {
    Write-Host "`n   Windows asked for a reboot to finish installing." -ForegroundColor Yellow
}

if ($failed) { exit 1 }

Write-Host "`nDone. Audio played to 'Virtual Cable Output' comes out of 'Virtual Cable Input'." -ForegroundColor Green
Write-Host 'Both endpoints should stay at their default format (48000 Hz, stereo) for the loopback to work.'
