/*
 * AlmanacLame.h
 * Copyright (c) 2024 Almanac Inc. — MIT License
 *
 * Opaque C wrapper around the vendored LAME 3.100 MP3 encoder.
 *
 * Design contract
 * ───────────────
 * • This header deliberately does NOT include "lame.h". The LAME public API
 *   is an implementation detail hidden inside AlmanacLame.c. Swift code
 *   (and any Objective-C consumer) works exclusively through the opaque
 *   `AlmanacLameHandle` type and the five functions below.
 * • All functions are thread-safe with respect to distinct handles.
 *   Do NOT share a single handle across threads.
 * • The caller owns the handle lifetime:
 *     AlmanacLameInit()  — allocates
 *     AlmanacLameClose() — deallocates (must be called exactly once per handle)
 */

#ifndef ALMANAC_LAME_H
#define ALMANAC_LAME_H

#include <stdint.h>   /* int16_t, uint8_t */

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque encoder handle. Internally wraps a `lame_t` pointer allocated by
 * lame_init(). Consumers must treat this as a black box.
 */
typedef void * AlmanacLameHandle;

/**
 * Allocates and configures a new LAME CBR encoder.
 *
 * @param sampleRate   Input AND output sample rate in Hz (the AVAudioConverter
 *                     delivers PCM at the requested rate, so in==out here).
 * @param numChannels  1 = mono, 2 = stereo.
 * @param bitRate      CBR bit rate in kbps (e.g., 128).
 * @return             An opaque handle on success, NULL on failure.
 */
AlmanacLameHandle AlmanacLameInit(int sampleRate, int numChannels, int bitRate);

/**
 * Encodes `samplesPerChannel` mono 16-bit signed PCM samples from `pcm` into
 * `mp3Out`.
 *
 * @param handle            A valid handle returned by AlmanacLameInit().
 * @param pcm               Input PCM buffer (mono; length == samplesPerChannel).
 * @param samplesPerChannel Number of mono samples in `pcm`.
 * @param mp3Out            Output buffer. Must be at least
 *                          (7200 + (int)(1.25 * samplesPerChannel)) bytes.
 * @param mp3OutSize        Byte capacity of `mp3Out`.
 * @return                  Bytes written into mp3Out (≥ 0), or a negative
 *                          LAME error code.
 */
int AlmanacLameEncode(AlmanacLameHandle handle,
                      const int16_t *pcm,
                      int samplesPerChannel,
                      uint8_t *mp3Out,
                      int mp3OutSize);

/**
 * Encodes `samplesPerChannel` interleaved stereo frames from `pcmInterleaved`
 * (layout: L0 R0 L1 R1 …; total length = samplesPerChannel * 2) into
 * `mp3Out`.
 *
 * @param handle            A valid handle.
 * @param pcmInterleaved    Interleaved stereo PCM (length == samplesPerChannel * 2).
 * @param samplesPerChannel Number of stereo frames (NOT total samples).
 * @param mp3Out            Output buffer. Same size rule as AlmanacLameEncode().
 * @param mp3OutSize        Byte capacity of `mp3Out`.
 * @return                  Bytes written (≥ 0), or a negative LAME error code.
 */
int AlmanacLameEncodeInterleaved(AlmanacLameHandle handle,
                                 const int16_t *pcmInterleaved,
                                 int samplesPerChannel,
                                 uint8_t *mp3Out,
                                 int mp3OutSize);

/**
 * Flushes any internally buffered MP3 frames from LAME into `mp3Out`.
 *
 * Must be called once before AlmanacLameClose() to avoid a truncated file.
 *
 * @param handle     A valid handle.
 * @param mp3Out     Output buffer; 7200 bytes is sufficient for the flush.
 * @param mp3OutSize Byte capacity of `mp3Out`.
 * @return           Bytes written (may be 0), or a negative LAME error code.
 */
int AlmanacLameFlush(AlmanacLameHandle handle,
                     uint8_t *mp3Out,
                     int mp3OutSize);

/**
 * Releases all resources associated with `handle`.
 *
 * After this call the handle is invalid. Passing NULL is a no-op.
 */
void AlmanacLameClose(AlmanacLameHandle handle);

#ifdef __cplusplus
}
#endif

#endif /* ALMANAC_LAME_H */
