/*
 * native-lib.cpp
 *
 * JNI bridge between RecordMp3Plugin.java and the vendored LAME 3.100 encoder.
 *
 * Naming convention: all exported symbols follow the JNI mangled form
 *   Java_com_almanacinc_record_1mp3_RecordMp3Plugin_<methodName>
 *
 * Design notes
 * ─────────────
 * • No global / static lame_t. Every call takes a jlong handle that wraps the
 *   lame_t pointer returned by initEncoder().  The Java layer owns the handle
 *   lifetime and must call closeEncoder() exactly once.
 * • Input (PCM) arrays are accessed with JNI_ABORT so the JVM is never asked
 *   to copy potentially modified data back.
 * • Output (MP3) arrays are accessed with 0 (commit) to allow the JVM to copy
 *   the encoded bytes back to the Java byte[].
 * • All functions perform a null-handle check and return a safe sentinel on
 *   failure rather than crashing.
 */

#include <jni.h>
#include <android/log.h>
#include <cstring>
#include <cstdlib>

/* LAME public header – lives in the same directory as config.h */
#include "lame.h"

#define LOG_TAG "AlmanacLame"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* ─────────────────────────────────────────────────────────────────────────
 * Helper: cast jlong handle → lame_t with null guard.
 * Returns nullptr if the handle is 0 and logs an error.
 * ───────────────────────────────────────────────────────────────────────── */
static inline lame_t handle_to_lame(jlong handle, const char* caller) {
    if (handle == 0) {
        LOGE("%s: called with null encoder handle", caller);
        return nullptr;
    }
    return reinterpret_cast<lame_t>(static_cast<uintptr_t>(handle));
}

extern "C" {

/* ─────────────────────────────────────────────────────────────────────────
 * initEncoder
 *
 * Allocates and configures a LAME encoder. Returns a jlong handle (non-zero)
 * on success, 0 on failure.
 *
 * Parameters
 *   inSampleRate  – hardware capture sample rate (always 44100 on Android)
 *   outSampleRate – desired output sample rate (may differ; LAME resamples)
 *   numChannels   – 1 (mono) or 2 (stereo)
 *   bitRate       – CBR bit rate in kbps (e.g., 128)
 * ───────────────────────────────────────────────────────────────────────── */
JNIEXPORT jlong JNICALL
Java_com_almanacinc_record_1mp3_RecordMp3Plugin_initEncoder(
        JNIEnv* /*env*/,
        jobject /*thiz*/,
        jint inSampleRate,
        jint outSampleRate,
        jint numChannels,
        jint bitRate) {

    lame_t lame = lame_init();
    if (!lame) {
        LOGE("initEncoder: lame_init() returned NULL");
        return 0L;
    }

    /* Input configuration: always 44100 Hz mono from AudioRecord */
    lame_set_in_samplerate(lame, inSampleRate);
    lame_set_num_channels(lame, numChannels);

    /* Output configuration */
    lame_set_out_samplerate(lame, outSampleRate);
    lame_set_brate(lame, bitRate);
    lame_set_VBR(lame, vbr_off);   /* CBR */
    lame_set_quality(lame, 5);     /* 0 = best, 9 = worst; 5 = good default */

    /* Channel / mode */
    if (numChannels == 1) {
        lame_set_mode(lame, MONO);
    } else {
        lame_set_mode(lame, JOINT_STEREO);
    }

    /* Silence informational messages */
    lame_set_errorf(lame, nullptr);
    lame_set_debugf(lame, nullptr);
    lame_set_msgf(lame,   nullptr);

    int ret = lame_init_params(lame);
    if (ret < 0) {
        LOGE("initEncoder: lame_init_params() failed with %d", ret);
        lame_close(lame);
        return 0L;
    }

    LOGI("initEncoder: created encoder handle=%p in=%d out=%d ch=%d br=%d",
         static_cast<void*>(lame), inSampleRate, outSampleRate,
         numChannels, bitRate);

    return static_cast<jlong>(reinterpret_cast<uintptr_t>(lame));
}

/* ─────────────────────────────────────────────────────────────────────────
 * encode  (mono path)
 *
 * Encodes `samplesPerChannel` mono 16-bit PCM samples from `pcm` into `mp3Out`.
 *
 * Returns the number of bytes written into mp3Out, or a negative LAME error
 * code on failure.
 *
 * mp3Out must be at least  7200 + (int)(1.25 * samplesPerChannel)  bytes.
 * ───────────────────────────────────────────────────────────────────────── */
JNIEXPORT jint JNICALL
Java_com_almanacinc_record_1mp3_RecordMp3Plugin_encode(
        JNIEnv* env,
        jobject /*thiz*/,
        jlong   handle,
        jshortArray pcm,
        jint    samplesPerChannel,
        jbyteArray mp3Out) {

    lame_t lame = handle_to_lame(handle, "encode");
    if (!lame) return -1;

    /* --- Acquire input buffer (read-only; JNI_ABORT prevents copy-back) --- */
    jshort* pcmBuf = env->GetShortArrayElements(pcm, nullptr);
    if (!pcmBuf) {
        LOGE("encode: GetShortArrayElements returned NULL");
        return -1;
    }

    /* --- Acquire output buffer --- */
    jbyte* outBuf = env->GetByteArrayElements(mp3Out, nullptr);
    if (!outBuf) {
        env->ReleaseShortArrayElements(pcm, pcmBuf, JNI_ABORT);
        LOGE("encode: GetByteArrayElements returned NULL");
        return -1;
    }

    jint outSize = env->GetArrayLength(mp3Out);

    int encoded = lame_encode_buffer(
        lame,
        pcmBuf,              /* left channel  (mono) */
        pcmBuf,              /* right channel (mono — LAME ignores for MONO mode) */
        samplesPerChannel,
        reinterpret_cast<unsigned char*>(outBuf),
        outSize
    );

    /* Release arrays */
    env->ReleaseShortArrayElements(pcm, pcmBuf, JNI_ABORT);
    /* Commit outBuf only when we have bytes to return */
    env->ReleaseByteArrayElements(mp3Out, outBuf, (encoded > 0) ? 0 : JNI_ABORT);

    if (encoded < 0) {
        LOGE("encode: lame_encode_buffer returned %d", encoded);
    }
    return encoded;
}

/* ─────────────────────────────────────────────────────────────────────────
 * encodeInterleaved  (stereo path)
 *
 * Encodes `samplesPerChannel` frames from an interleaved stereo buffer
 * (L0 R0 L1 R1 … of length samplesPerChannel*2) into `mp3Out`.
 *
 * Returns bytes written, or a negative LAME error code.
 * ───────────────────────────────────────────────────────────────────────── */
JNIEXPORT jint JNICALL
Java_com_almanacinc_record_1mp3_RecordMp3Plugin_encodeInterleaved(
        JNIEnv* env,
        jobject /*thiz*/,
        jlong   handle,
        jshortArray pcmInterleaved,
        jint    samplesPerChannel,
        jbyteArray mp3Out) {

    lame_t lame = handle_to_lame(handle, "encodeInterleaved");
    if (!lame) return -1;

    jshort* pcmBuf = env->GetShortArrayElements(pcmInterleaved, nullptr);
    if (!pcmBuf) {
        LOGE("encodeInterleaved: GetShortArrayElements returned NULL");
        return -1;
    }

    jbyte* outBuf = env->GetByteArrayElements(mp3Out, nullptr);
    if (!outBuf) {
        env->ReleaseShortArrayElements(pcmInterleaved, pcmBuf, JNI_ABORT);
        LOGE("encodeInterleaved: GetByteArrayElements returned NULL");
        return -1;
    }

    jint outSize = env->GetArrayLength(mp3Out);

    int encoded = lame_encode_buffer_interleaved(
        lame,
        pcmBuf,
        samplesPerChannel,
        reinterpret_cast<unsigned char*>(outBuf),
        outSize
    );

    env->ReleaseShortArrayElements(pcmInterleaved, pcmBuf, JNI_ABORT);
    env->ReleaseByteArrayElements(mp3Out, outBuf, (encoded > 0) ? 0 : JNI_ABORT);

    if (encoded < 0) {
        LOGE("encodeInterleaved: lame_encode_buffer_interleaved returned %d", encoded);
    }
    return encoded;
}

/* ─────────────────────────────────────────────────────────────────────────
 * flush
 *
 * Flushes any remaining internally buffered MP3 frames from LAME into mp3Out.
 * Must be called before closeEncoder() to avoid truncated files.
 *
 * Returns bytes written (may be 0 if nothing buffered), or negative on error.
 * ───────────────────────────────────────────────────────────────────────── */
JNIEXPORT jint JNICALL
Java_com_almanacinc_record_1mp3_RecordMp3Plugin_flush(
        JNIEnv* env,
        jobject /*thiz*/,
        jlong   handle,
        jbyteArray mp3Out) {

    lame_t lame = handle_to_lame(handle, "flush");
    if (!lame) return -1;

    jbyte* outBuf = env->GetByteArrayElements(mp3Out, nullptr);
    if (!outBuf) {
        LOGE("flush: GetByteArrayElements returned NULL");
        return -1;
    }

    jint outSize = env->GetArrayLength(mp3Out);

    int flushed = lame_encode_flush(
        lame,
        reinterpret_cast<unsigned char*>(outBuf),
        outSize
    );

    env->ReleaseByteArrayElements(mp3Out, outBuf, (flushed > 0) ? 0 : JNI_ABORT);

    if (flushed < 0) {
        LOGE("flush: lame_encode_flush returned %d", flushed);
    }
    return flushed;
}

/* ─────────────────────────────────────────────────────────────────────────
 * closeEncoder
 *
 * Releases the LAME encoder and all internally allocated memory.
 * After this call the handle is invalid; the Java layer must discard it.
 * ───────────────────────────────────────────────────────────────────────── */
JNIEXPORT void JNICALL
Java_com_almanacinc_record_1mp3_RecordMp3Plugin_closeEncoder(
        JNIEnv* /*env*/,
        jobject /*thiz*/,
        jlong handle) {

    lame_t lame = handle_to_lame(handle, "closeEncoder");
    if (!lame) return;

    lame_close(lame);
    LOGI("closeEncoder: released encoder handle=%p", static_cast<void*>(lame));
}

} /* extern "C" */
