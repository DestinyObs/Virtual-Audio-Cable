VIRTUAL AUDIO CABLE - TEST-SIGNED PACKAGE (x64)
===============================================

What it does
------------
Adds two audio devices to Windows:

  Virtual Cable Output   (a speaker / playback device)
  Virtual Cable Input    (a microphone / recording device)

Anything played to "Virtual Cable Output" comes out of "Virtual Cable Input".
Latency is kept under about 60 ms.

Requirements
------------
- Windows 10 version 1903 or later, or Windows 11, 64-bit (x64).
- Secure Boot turned OFF in the PC firmware (BIOS/UEFI).
- Test signing turned ON (Install.ps1 does this for you, one reboot).
- Administrator rights.

This driver is test-signed, not signed by Microsoft. Windows only loads it in
test-signing mode, which shows a "Test Mode" watermark on the desktop. Use it
on a dedicated or test machine, not on production or customer systems.

Package contents
----------------
  driver\VirtualAudioDriver.sys       the driver
  driver\VirtualAudioDriver.inf       install information
  driver\virtualaudiodriver.cat       signed catalog
  VirtualAudioCable-TestCert.cer      test certificate the package is signed with
  Install.ps1                         installer
  Uninstall.ps1                       uninstaller

Install
-------
1. Turn Secure Boot off in the firmware settings if it is on.
2. Open PowerShell as Administrator in this folder and run:

     powershell -ExecutionPolicy Bypass -File .\Install.ps1

3. If test signing was off, the script turns it on and asks to reboot.
   After the reboot, run the same command again to finish.
4. The script confirms each step before making a change. Add -Yes to skip
   the prompts.

Use
---
- In the app that should send audio, choose "Virtual Cable Output" as the
  speaker or output device.
- In the app that should receive it, choose "Virtual Cable Input" as the
  microphone or input device.
- Keep both devices at their default format, 48000 Hz stereo
  (Sound settings > device > Properties > Advanced). Other formats produce
  silence on the input side.

Uninstall
---------
     powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1

Removes the device and driver package, then offers to remove the test
certificate and turn test signing off. Secure Boot can be turned back on
after test signing is off and the PC has rebooted.

Troubleshooting
---------------
Code 52 in Device Manager
    Windows does not trust the signature. Check that Secure Boot is off and
    test signing is on ("bcdedit /enum {current}" shows "testsigning Yes"),
    then reboot.

No sound on Virtual Cable Input
    Check that the sending app is playing to Virtual Cable Output, and that
    both devices are set to 48000 Hz stereo.

Credits
-------
Based on Virtual-Audio-Driver by MikeTheTech (MIT licence), which is based on
the Microsoft SysVAD sample. See LICENSE and THIRD_PARTY_NOTICES.md in the
source repository.
