/*
 * AlmanacLame.c
 * Copyright (c) 2024 Almanac Inc. — MIT License
 *
 * C implementation of the AlmanacLame wrapper around LAME 3.100.
 *
 * This is the ONLY file in the iOS target that #includes "lame.h".
 * All other files (Swift, umbrella header) use AlmanacLame.h exclusively,
 * which exposes only the opaque AlmanacLameHandle type.
 *
 * Build-time requirements
 * ───────────────────────
 * • Compiled with -DHAVE_CONFIG_H (set via podspec GCC_PREPROCESSOR_DEFINITIONS).
 * • HEADER_SEARCH_PATHS must include:
 *     $(PODS_TARGET_SRCROOT)/Classes/lame/include   (for lame.h)
 *     $(PODS_TARGET_SRCROOT)/Classes/lame            (for config.h)
 */

#include "AlmanacLame.h"

/*
 * lame.h is found via HEADER_SEARCH_PATHS →
 *   $(PODS_TARGET_SRCROOT)/Classes/lame/include/lame.h
 * which is placed there by fetch_lame.sh.
 */
#include "lame.h"

#include <stdlib.h>
#include <string.h>

/* ─────────────────────────────────────────────────────────────────────────
 * AlmanacLameInit
 * ───────────────────────────────────────────────────────────────────────── */
AlmanacLameHandle AlmanacLameInit(int sampleRate, int numChannels, int bitRate) {
    lame_t lame = lame_init();
    if (!lame) return NULL;

    /*
     * On iOS the AVAudioConverter delivers PCM already at the requested
     * sampleRate and numChannels, so in_samplerate == out_samplerate.
     */
    lame_set_in_samplerate(lame, sampleRate);
    lame_set_out_samplerate(lame, sampleRate);
    lame_set_num_channels(lame, numChannels);
    lame_set_brate(lame, bitRate);
    lame_set_VBR(lame, vbr_off);   /* CBR */
    lame_set_quality(lame, 5);     /* 0 = best, 9 = worst */

    if (numChannels == 1) {
        lame_set_mode(lame, MONO);
    } else {
        lame_set_mode(lame, JOINT_STEREO);
    }

    /* Suppress LAME console output. */
    lame_set_errorf(lame, NULL);
    lame_set_debugf(lame, NULL);
    lame_set_msgf(lame,   NULL);

    if (lame_init_params(lame) < 0) {
        lame_close(lame);
        return NULL;
    }

    return (AlmanacLameHandle)lame;
}

/* ─────────────────────────────────────────────────────────────────────────
 * AlmanacLameEncode  (mono path)
 * ───────────────────────────────────────────────────────────────────────── */
int AlmanacLameEncode(AlmanacLameHandle handle,
                      const int16_t *pcm,
                      int samplesPerChannel,
                      uint8_t *mp3Out,
                      int mp3OutSize) {
    if (!handle || !pcm || !mp3Out) return -1;
    lame_t lame = (lame_t)handle;

    /*
     * lame_encode_buffer takes non-const short* for left and right channels.
     * The LAME API does not modify the input — the cast is safe.
     */
    return lame_encode_buffer(
        lame,
        (short *)pcm,   /* left  channel (mono) */
        (short *)pcm,   /* right channel (LAME ignores for MONO mode) */
        samplesPerChannel,
        mp3Out,
        mp3OutSize
    );
}

/* ─────────────────────────────────────────────────────────────────────────
 * AlmanacLameEncodeInterleaved  (stereo path)
 * ───────────────────────────────────────────────────────────────────────── */
int AlmanacLameEncodeInterleaved(AlmanacLameHandle handle,
                                 const int16_t *pcmInterleaved,
                                 int samplesPerChannel,
                                 uint8_t *mp3Out,
                                 int mp3OutSize) {
    if (!handle || !pcmInterleaved || !mp3Out) return -1;
    lame_t lame = (lame_t)handle;

    return lame_encode_buffer_interleaved(
        lame,
        (short *)pcmInterleaved,
        samplesPerChannel,
        mp3Out,
        mp3OutSize
    );
}

/* ─────────────────────────────────────────────────────────────────────────
 * AlmanacLameFlush
 * ───────────────────────────────────────────────────────────────────────── */
int AlmanacLameFlush(AlmanacLameHandle handle,
                     uint8_t *mp3Out,
                     int mp3OutSize) {
    if (!handle || !mp3Out) return -1;
    lame_t lame = (lame_t)handle;
    return lame_encode_flush(lame, mp3Out, mp3OutSize);
}

/* ─────────────────────────────────────────────────────────────────────────
 * AlmanacLameClose
 * ───────────────────────────────────────────────────────────────────────── */
void AlmanacLameClose(AlmanacLameHandle handle) {
    if (!handle) return;
    lame_close((lame_t)handle);
}
