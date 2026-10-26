# Changes in this fork

Version 1.1.0.0

## Driver

- **Speaker-to-microphone loopback.** Audio rendered to the speaker endpoint is now played out of the microphone endpoint, so the device works as a virtual audio cable. Upstream, the speaker discarded audio and the microphone produced silence.
  - New `Source/Inc/loopback.h` and `Source/Main/loopback.cpp`: a 500 ms non-paged ring buffer in 48 kHz stereo 32-bit PCM, protected by a spin lock, with 16/24/32-bit conversion and a 60 ms latency cap.
  - `CMiniportWaveRTStream::LoopbackRender` feeds the ring buffer from the render path. It runs regardless of the `DoNotCreateDataFiles` setting.
  - `CMiniportWaveRTStream::WriteBytes` fills the capture buffer from the ring buffer and pads underruns with silence.
  - Only 48 kHz stereo integer PCM is looped, which is the default format of both endpoints. Other formats produce silence on the capture side.

## INF

- The minimum OS changes from build 22000 (Windows 11 only) to build 18362 (Windows 10 1903 and later), matching the supported OS stated in the README.
- Endpoint names are now "Virtual Cable Output" and "Virtual Cable Input".
- `DriverVer` is 1.1.0.0.

## Build and packaging

- New `.github/workflows/build-test-signed.yml` builds x64 Release, test-signs the `.sys` and catalog with a throwaway self-signed certificate, and uploads a ready-to-install package.
- `VAD-compile-and-sign.yml` is now manual-only, because it needs upstream SignPath secrets.
- New `tools/Install.ps1` and `tools/Uninstall.ps1` are confirmation-gated installers. They check Secure Boot and test signing, trust the test certificate, add the driver package, and create the root-enumerated device without devcon.
- New `tools/README.txt` is the end-user instructions shipped in the package.

## Not done

- Production signing. Loading on a machine with Secure Boot on requires Microsoft attestation signing through Partner Center with an EV code-signing certificate.
- ARM64 packaging. The loopback code is architecture-neutral, but only x64 is packaged.
