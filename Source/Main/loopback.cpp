/*++

Module Name:

    loopback.cpp

Abstract:

    Speaker-to-microphone loopback. See loopback.h for the design notes.

--*/

#include "definitions.h"
#include <ksmedia.h>
#include "loopback.h"

#pragma code_seg()

//
// Shared ring buffer. Lives in the driver image's non-paged data section.
// Zero-initialised storage is a valid initial state for KSPIN_LOCK.
//
static LONG       g_LoopbackRing[LOOPBACK_RING_FRAMES * LOOPBACK_CHANNELS];
static KSPIN_LOCK g_LoopbackLock;
static ULONG      g_LoopbackWriteFrame;     // next frame index to write
static ULONG      g_LoopbackFramesQueued;   // frames available to read

//=============================================================================
// Sample conversion helpers. Stream samples are little-endian, signed and
// left-justified in their container. The ring stores 32-bit samples.
//=============================================================================
static __forceinline LONG
LoopbackDecodeSample
(
    _In_reads_bytes_(BytesPerSample) const BYTE* Sample,
    _In_ ULONG                                   BytesPerSample
)
{
    ULONG value = 0;

    switch (BytesPerSample)
    {
    case 2:
        value = ((ULONG)Sample[0] << 16) | ((ULONG)Sample[1] << 24);
        break;
    case 3:
        value = ((ULONG)Sample[0] << 8) | ((ULONG)Sample[1] << 16) | ((ULONG)Sample[2] << 24);
        break;
    case 4:
        value = (ULONG)Sample[0] | ((ULONG)Sample[1] << 8) |
                ((ULONG)Sample[2] << 16) | ((ULONG)Sample[3] << 24);
        break;
    default:
        break;
    }

    return (LONG)value;
}

static __forceinline VOID
LoopbackEncodeSample
(
    _In_ LONG                                     Value,
    _Out_writes_bytes_(BytesPerSample) BYTE*      Sample,
    _In_ ULONG                                    BytesPerSample
)
{
    ULONG value = (ULONG)Value;

    switch (BytesPerSample)
    {
    case 2:
        Sample[0] = (BYTE)(value >> 16);
        Sample[1] = (BYTE)(value >> 24);
        break;
    case 3:
        Sample[0] = (BYTE)(value >> 8);
        Sample[1] = (BYTE)(value >> 16);
        Sample[2] = (BYTE)(value >> 24);
        break;
    case 4:
        Sample[0] = (BYTE)(value);
        Sample[1] = (BYTE)(value >> 8);
        Sample[2] = (BYTE)(value >> 16);
        Sample[3] = (BYTE)(value >> 24);
        break;
    default:
        break;
    }
}

//=============================================================================
BOOLEAN
LoopbackIsFormatSupported
(
    _In_opt_ PWAVEFORMATEXTENSIBLE  WaveFormat,
    _Out_    ULONG*                 BytesPerSample
)
{
    *BytesPerSample = 0;

    if (WaveFormat == NULL)
    {
        return FALSE;
    }

    const WAVEFORMATEX* format = &WaveFormat->Format;

    if (format->nSamplesPerSec != LOOPBACK_SAMPLE_RATE ||
        format->nChannels      != LOOPBACK_CHANNELS)
    {
        return FALSE;
    }

    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE)
    {
        if (!IsEqualGUIDAligned(WaveFormat->SubFormat, KSDATAFORMAT_SUBTYPE_PCM))
        {
            return FALSE;
        }
    }
    else if (format->wFormatTag != WAVE_FORMAT_PCM)
    {
        return FALSE;
    }

    ULONG bytesPerSample = format->nBlockAlign / format->nChannels;

    if (bytesPerSample < 2 || bytesPerSample > 4 ||
        format->nBlockAlign != bytesPerSample * format->nChannels)
    {
        return FALSE;
    }

    *BytesPerSample = bytesPerSample;
    return TRUE;
}

//=============================================================================
VOID
LoopbackWrite
(
    _In_reads_bytes_(ByteCount) const BYTE* Source,
    _In_ ULONG                              ByteCount,
    _In_ ULONG                              BytesPerSample
)
{
    ULONG frameBytes = BytesPerSample * LOOPBACK_CHANNELS;

    if (Source == NULL || frameBytes == 0)
    {
        return;
    }

    ULONG frames = ByteCount / frameBytes;
    KIRQL oldIrql;

    KeAcquireSpinLock(&g_LoopbackLock, &oldIrql);

    for (ULONG i = 0; i < frames; i++)
    {
        LONG* destination = &g_LoopbackRing[g_LoopbackWriteFrame * LOOPBACK_CHANNELS];

        for (ULONG channel = 0; channel < LOOPBACK_CHANNELS; channel++)
        {
            destination[channel] = LoopbackDecodeSample(Source, BytesPerSample);
            Source += BytesPerSample;
        }

        g_LoopbackWriteFrame = (g_LoopbackWriteFrame + 1) % LOOPBACK_RING_FRAMES;

        if (g_LoopbackFramesQueued < LOOPBACK_RING_FRAMES)
        {
            g_LoopbackFramesQueued++;
        }
    }

    KeReleaseSpinLock(&g_LoopbackLock, oldIrql);
}

//=============================================================================
VOID
LoopbackRead
(
    _Out_writes_bytes_(ByteCount) BYTE* Destination,
    _In_ ULONG                          ByteCount,
    _In_ ULONG                          BytesPerSample
)
{
    ULONG frameBytes = BytesPerSample * LOOPBACK_CHANNELS;

    if (Destination == NULL)
    {
        return;
    }

    if (frameBytes == 0)
    {
        RtlZeroMemory(Destination, ByteCount);
        return;
    }

    ULONG frames    = ByteCount / frameBytes;
    ULONG remainder = ByteCount % frameBytes;
    KIRQL oldIrql;

    KeAcquireSpinLock(&g_LoopbackLock, &oldIrql);

    //
    // Keep latency bounded: if the microphone has fallen behind (for example
    // it started after the speaker), drop the oldest audio.
    //
    ULONG queued = g_LoopbackFramesQueued;
    ULONG maxQueued = LOOPBACK_MAX_LATENCY_FRAMES + frames;

    if (queued > maxQueued)
    {
        queued = maxQueued;
    }

    ULONG readFrame = (g_LoopbackWriteFrame + LOOPBACK_RING_FRAMES - queued) % LOOPBACK_RING_FRAMES;
    ULONG copyFrames = min(frames, queued);

    for (ULONG i = 0; i < copyFrames; i++)
    {
        const LONG* source = &g_LoopbackRing[readFrame * LOOPBACK_CHANNELS];

        for (ULONG channel = 0; channel < LOOPBACK_CHANNELS; channel++)
        {
            LoopbackEncodeSample(source[channel], Destination, BytesPerSample);
            Destination += BytesPerSample;
        }

        readFrame = (readFrame + 1) % LOOPBACK_RING_FRAMES;
    }

    g_LoopbackFramesQueued = queued - copyFrames;

    KeReleaseSpinLock(&g_LoopbackLock, oldIrql);

    //
    // Underrun (speaker idle or behind): pad with silence.
    //
    ULONG silenceBytes = (frames - copyFrames) * frameBytes + remainder;

    if (silenceBytes > 0)
    {
        RtlZeroMemory(Destination, silenceBytes);
    }
}
