/*++

Module Name:

    loopback.h

Abstract:

    Speaker-to-microphone loopback.

    Audio rendered to the virtual speaker endpoint is copied into a shared
    ring buffer and played back out of the virtual microphone endpoint, so
    the pair behaves as a virtual audio cable.

    The ring buffer holds 48 kHz, 2-channel, 32-bit signed PCM (samples are
    left-justified, matching WAVEFORMATEXTENSIBLE convention). Each endpoint
    converts between its own stream format and the ring format. Only 48 kHz
    stereo integer PCM is looped; any other stream format produces silence on
    the microphone side. 48 kHz stereo is the default format of both
    endpoints, and the Windows audio engine resamples for applications in
    shared mode, so this covers normal use.

    The ring buffer and its spin lock are static and zero-initialised, which
    is a valid initial state for a KSPIN_LOCK, so no explicit setup is needed
    in DriverEntry. All functions are callable at IRQL <= DISPATCH_LEVEL.

--*/

#ifndef _VIRTUALAUDIODRIVER_LOOPBACK_H_
#define _VIRTUALAUDIODRIVER_LOOPBACK_H_

#define LOOPBACK_SAMPLE_RATE        48000
#define LOOPBACK_CHANNELS           2

// Ring capacity: 500 ms.
#define LOOPBACK_RING_FRAMES        (LOOPBACK_SAMPLE_RATE / 2)

// Maximum latency kept between speaker and microphone: 60 ms.
// Older audio is dropped so the microphone never lags far behind.
#define LOOPBACK_MAX_LATENCY_FRAMES (LOOPBACK_SAMPLE_RATE * 60 / 1000)

//
// Returns TRUE if the stream format can be looped and sets *BytesPerSample
// to the container size of one sample (2, 3 or 4 bytes).
//
BOOLEAN
LoopbackIsFormatSupported
(
    _In_opt_ PWAVEFORMATEXTENSIBLE  WaveFormat,
    _Out_    ULONG*                 BytesPerSample
);

//
// Speaker side: copy rendered audio into the ring buffer.
//
VOID
LoopbackWrite
(
    _In_reads_bytes_(ByteCount) const BYTE* Source,
    _In_ ULONG                              ByteCount,
    _In_ ULONG                              BytesPerSample
);

//
// Microphone side: fill the capture buffer from the ring buffer.
// Any shortfall is filled with silence.
//
VOID
LoopbackRead
(
    _Out_writes_bytes_(ByteCount) BYTE* Destination,
    _In_ ULONG                          ByteCount,
    _In_ ULONG                          BytesPerSample
);

#endif // _VIRTUALAUDIODRIVER_LOOPBACK_H_
