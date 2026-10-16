// Copyright (c) 2024 Almanac Inc. — MIT License
// See LICENSE at the repository root for full text.
package com.almanacinc.record_mp3;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.Looper;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;

/**
 * RecordMp3Plugin — Android implementation of the almanacinc_record_mp3 Flutter plugin.
 *
 * <p>Architecture overview:
 * <ol>
 *   <li>Microphone capture is performed by {@link AudioRecord} at 44 100 Hz mono (the only rate
 *       guaranteed on all Android devices).</li>
 *   <li>PCM frames flow through JNI into the vendored LAME 3.100 encoder, which resamples to the
 *       requested output rate if necessary.</li>
 *   <li>Encoded MP3 frames are written synchronously to a {@link BufferedOutputStream}.</li>
 *   <li>All UI-thread interactions (Result replies, EventSink events) are posted via a
 *       main-looper {@link Handler}.</li>
 * </ol>
 *
 * <p>Threading model:
 * <ul>
 *   <li>A single dedicated worker {@link Thread} owns AudioRecord, the LAME handle, and the file
 *       stream for the lifetime of one recording session.</li>
 *   <li>Pause suspends the worker inside a {@code synchronized} / {@code wait()} block after
 *       stopping AudioRecord. Resume calls {@code notifyAll()} and restarts AudioRecord.</li>
 *   <li>Stop clears {@code isRecording}, stops AudioRecord (which unblocks any pending
 *       {@code AudioRecord.read()}), notifies the worker if paused, then calls plain
 *       {@code join()} — no arbitrary timeout.</li>
 * </ul>
 */
public class RecordMp3Plugin
        implements FlutterPlugin,
                   MethodCallHandler,
                   ActivityAware,
                   PluginRegistry.RequestPermissionsResultListener,
                   EventChannel.StreamHandler {

    // ─────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────

    private static final String METHOD_CHANNEL  = "com.almanacinc.record_mp3";
    private static final String EVENT_CHANNEL   = "com.almanacinc.record_mp3/events";
    private static final int    PERMISSION_CODE  = 0x4D50; // 'MP'

    /** AudioRecord always captures at 44 100 Hz mono — the guaranteed rate on Android. */
    private static final int CAPTURE_SAMPLE_RATE = 44100;

    private static final String STATUS_IDLE      = "idle";
    private static final String STATUS_RECORDING = "recording";
    private static final String STATUS_PAUSED    = "paused";

    // ─────────────────────────────────────────────────────────────────────
    // Flutter channel objects
    // ─────────────────────────────────────────────────────────────────────

    private MethodChannel  methodChannel;
    private EventChannel   eventChannel;
    private EventChannel.EventSink eventSink;
    private FlutterPlugin.FlutterPluginBinding pluginBinding;

    /** Posts all replies and events onto the platform main thread. */
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    // ─────────────────────────────────────────────────────────────────────
    // Activity / permission state
    // ─────────────────────────────────────────────────────────────────────

    private Activity activity;
    private ActivityPluginBinding activityBinding;

    /** Pending start() Result awaiting the permission dialog. */
    private Result pendingPermissionResult;
    /** Pending start() arguments awaiting permission grant. */
    private Map<String, Object> pendingStartArgs;

    // ─────────────────────────────────────────────────────────────────────
    // Recording session state
    // ─────────────────────────────────────────────────────────────────────

    private final AtomicBoolean isRecording = new AtomicBoolean(false);
    private final AtomicBoolean isPaused    = new AtomicBoolean(false);

    private AudioRecord audioRecord;
    private Thread      workerThread;
    private long        lameHandle = 0L;  // opaque JNI handle

    private OutputStream outputStream;
    private String       outputFilePath;

    /** Lock object used for pause/resume synchronisation in the worker. */
    private final Object pauseLock = new Object();

    // ─────────────────────────────────────────────────────────────────────
    // JNI declarations
    // ─────────────────────────────────────────────────────────────────────

    static {
        System.loadLibrary("almanac_record_mp3");
    }

    private native long  initEncoder(int inSampleRate, int outSampleRate,
                                     int numChannels, int bitRate);
    private native int   encode(long handle, short[] pcm,
                                int samplesPerChannel, byte[] mp3Out);
    private native int   encodeInterleaved(long handle, short[] pcmInterleaved,
                                           int samplesPerChannel, byte[] mp3Out);
    private native int   flush(long handle, byte[] mp3Out);
    private native void  closeEncoder(long handle);

    // ─────────────────────────────────────────────────────────────────────
    // FlutterPlugin — attach / detach
    // ─────────────────────────────────────────────────────────────────────

    @Override
    public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
        pluginBinding = binding;

        methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
        methodChannel.setMethodCallHandler(this);

        eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
        eventChannel.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {
        // Safely stop any active recording before the engine tears down.
        if (isRecording.get()) {
            stopRecordingInternal();
        }
        methodChannel.setMethodCallHandler(null);
        eventChannel.setStreamHandler(null);
        pluginBinding = null;
    }

    // ─────────────────────────────────────────────────────────────────────
    // ActivityAware
    // ─────────────────────────────────────────────────────────────────────

    @Override
    public void onAttachedToActivity(ActivityPluginBinding binding) {
        activity = binding.getActivity();
        activityBinding = binding;
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        teardownActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        teardownActivity();
    }

    private void teardownActivity() {
        if (activityBinding != null) {
            activityBinding.removeRequestPermissionsResultListener(this);
        }
        activity       = null;
        activityBinding = null;
    }

    // ─────────────────────────────────────────────────────────────────────
    // EventChannel.StreamHandler
    // ─────────────────────────────────────────────────────────────────────

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        eventSink = events;
    }

    @Override
    public void onCancel(Object arguments) {
        eventSink = null;
    }

    // ─────────────────────────────────────────────────────────────────────
    // MethodCallHandler
    // ─────────────────────────────────────────────────────────────────────

    @Override
    public void onMethodCall(MethodCall call, Result result) {
        switch (call.method) {
            case "hasPermission":
                handleHasPermission(result);
                break;
            case "start":
                handleStart(call, result);
                break;
            case "pause":
                handlePause(result);
                break;
            case "resume":
                handleResume(result);
                break;
            case "stop":
                handleStop(result);
                break;
            default:
                result.notImplemented();
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permission handling
    // ─────────────────────────────────────────────────────────────────────

    private void handleHasPermission(Result result) {
        if (activity == null) {
            // No activity — cannot prompt; report based on static grant status.
            boolean granted = pluginBinding != null &&
                ContextCompat.checkSelfPermission(
                    pluginBinding.getApplicationContext(),
                    Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
            replyBool(result, granted);
            return;
        }

        int status = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.RECORD_AUDIO);
        if (status == PackageManager.PERMISSION_GRANTED) {
            replyBool(result, true);
        } else {
            ActivityCompat.requestPermissions(
                activity,
                new String[]{Manifest.permission.RECORD_AUDIO},
                PERMISSION_CODE);
            // Result resolved in onRequestPermissionsResult below.
            pendingPermissionResult = result;
            pendingStartArgs        = null;
        }
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode,
                                              String[] permissions,
                                              int[] grantResults) {
        if (requestCode != PERMISSION_CODE) return false;

        boolean granted = grantResults.length > 0
            && grantResults[0] == PackageManager.PERMISSION_GRANTED;

        if (pendingPermissionResult != null && pendingStartArgs == null) {
            // Called from hasPermission().
            final Result r = pendingPermissionResult;
            pendingPermissionResult = null;
            replyBool(r, granted);
        } else if (pendingPermissionResult != null) {
            // Called from start() which requested permission on the fly.
            final Result r = pendingPermissionResult;
            final Map<String, Object> args = pendingStartArgs;
            pendingPermissionResult = null;
            pendingStartArgs        = null;
            if (granted) {
                startRecordingWithArgs(args, r);
            } else {
                replyBool(r, false);
            }
        }
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // start()
    // ─────────────────────────────────────────────────────────────────────

    @SuppressWarnings("unchecked")
    private void handleStart(MethodCall call, Result result) {
        if (isRecording.get()) {
            replyBool(result, false);
            return;
        }

        // Collect arguments from the method call.
        final Map<String, Object> args = new HashMap<>();
        args.put("filePath",    call.argument("filePath"));
        args.put("sampleRate",  call.argument("sampleRate"));
        args.put("bitRate",     call.argument("bitRate"));
        args.put("numChannels", call.argument("numChannels"));

        if (activity == null) {
            // If no activity is present we cannot request a permission dialog.
            // Fall through to check static grant and attempt to start anyway.
            int status = pluginBinding == null ? PackageManager.PERMISSION_DENIED
                : ContextCompat.checkSelfPermission(
                    pluginBinding.getApplicationContext(),
                    Manifest.permission.RECORD_AUDIO);
            if (status != PackageManager.PERMISSION_GRANTED) {
                sendError("RECORD_AUDIO permission not granted and no Activity available.");
                replyBool(result, false);
                return;
            }
            startRecordingWithArgs(args, result);
            return;
        }

        // Check / request permission.
        int status = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.RECORD_AUDIO);
        if (status == PackageManager.PERMISSION_GRANTED) {
            startRecordingWithArgs(args, result);
        } else {
            // Permission not yet granted — request it and defer start.
            ActivityCompat.requestPermissions(
                activity,
                new String[]{Manifest.permission.RECORD_AUDIO},
                PERMISSION_CODE);
            pendingPermissionResult = result;
            pendingStartArgs        = args;
        }
    }

    private void startRecordingWithArgs(Map<String, Object> args, Result result) {
        final String filePath    = (String)  args.get("filePath");
        final int    sampleRate  = toInt(args.get("sampleRate"),  44100);
        final int    bitRate     = toInt(args.get("bitRate"),     128);
        final int    numChannels = toInt(args.get("numChannels"), 1);

        // ── Validate output directory ────────────────────────────────────
        if (filePath == null || filePath.isEmpty()) {
            sendError("filePath is null or empty.");
            replyBool(result, false);
            return;
        }
        File outputFile = new File(filePath);
        File parentDir  = outputFile.getParentFile();
        if (parentDir == null || !parentDir.exists() || !parentDir.canWrite()) {
            sendError("Parent directory does not exist or is not writable: "
                      + (parentDir == null ? "null" : parentDir.getAbsolutePath()));
            replyBool(result, false);
            return;
        }

        // ── Initialise LAME encoder ──────────────────────────────────────
        long handle = initEncoder(CAPTURE_SAMPLE_RATE, sampleRate, numChannels, bitRate);
        if (handle == 0L) {
            sendError("LAME initEncoder failed.");
            replyBool(result, false);
            return;
        }

        // ── Open output stream ───────────────────────────────────────────
        OutputStream stream;
        try {
            stream = new BufferedOutputStream(new FileOutputStream(outputFile));
        } catch (IOException e) {
            closeEncoder(handle);
            sendError("Cannot open output file: " + e.getMessage());
            replyBool(result, false);
            return;
        }

        // ── Initialise AudioRecord ───────────────────────────────────────
        int minBufSize = AudioRecord.getMinBufferSize(
            CAPTURE_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT);

        if (minBufSize == AudioRecord.ERROR
                || minBufSize == AudioRecord.ERROR_BAD_VALUE) {
            closeEncoder(handle);
            try { stream.close(); } catch (IOException ignored) {}
            sendError("AudioRecord.getMinBufferSize() returned error: " + minBufSize);
            replyBool(result, false);
            return;
        }

        // Use 2× minimum for a comfortable read headroom.
        final int captureBufSize = minBufSize * 2;

        AudioRecord recorder = new AudioRecord(
            MediaRecorder.AudioSource.MIC,
            CAPTURE_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            captureBufSize);

        if (recorder.getState() != AudioRecord.STATE_INITIALIZED) {
            recorder.release();
            closeEncoder(handle);
            try { stream.close(); } catch (IOException ignored) {}
            sendError("AudioRecord failed to initialise.");
            replyBool(result, false);
            return;
        }

        // ── Commit session state ─────────────────────────────────────────
        audioRecord    = recorder;
        lameHandle     = handle;
        outputStream   = stream;
        outputFilePath = filePath;
        isRecording.set(true);
        isPaused.set(false);

        final int    finalNumChannels = numChannels;
        final long   finalHandle      = handle;
        final Result finalResult      = result;

        // ── Start worker thread ──────────────────────────────────────────
        workerThread = new Thread(() ->
            recordingLoop(finalHandle, finalNumChannels, captureBufSize));
        workerThread.setName("almanac-recorder");
        workerThread.start();

        recorder.startRecording();

        replyBool(finalResult, true);
        sendStatus(STATUS_RECORDING);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Worker recording loop
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Runs on the dedicated worker thread. Reads PCM from AudioRecord, encodes
     * via LAME, and writes MP3 bytes to the output stream. Respects pause/resume
     * via a {@code synchronized} wait on {@link #pauseLock}.
     */
    private void recordingLoop(long handle, int numChannels, int captureBufSize) {
        // samplesPerChannel == number of mono samples per AudioRecord.read().
        final int samplesPerChannel = captureBufSize / 2; // 2 bytes per short
        final int mp3BufSize        = 7200 + (int)(1.25 * samplesPerChannel);
        final byte[] mp3Buf         = new byte[mp3BufSize];

        // PCM read buffer: always mono from the capture side.
        final short[] pcmMono = new short[samplesPerChannel];

        // Stereo interleaved buffer, allocated only when numChannels == 2.
        final short[] pcmStereo = (numChannels == 2)
            ? new short[samplesPerChannel * 2] : null;

        while (isRecording.get()) {
            // ── Pause gate ───────────────────────────────────────────────
            synchronized (pauseLock) {
                while (isPaused.get() && isRecording.get()) {
                    try {
                        pauseLock.wait();
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            }
            if (!isRecording.get()) break;

            // ── Read PCM ─────────────────────────────────────────────────
            int readSamples = audioRecord.read(pcmMono, 0, samplesPerChannel);
            if (readSamples <= 0) {
                // read() returns 0 or negative when AudioRecord is stopped;
                // this is the normal unblock path when stop() is called.
                break;
            }

            // ── Encode ───────────────────────────────────────────────────
            int encoded;
            if (numChannels == 1) {
                encoded = encode(handle, pcmMono, readSamples, mp3Buf);
            } else {
                // Duplicate mono capture into interleaved stereo (L0 R0 L1 R1 …).
                for (int i = 0; i < readSamples; i++) {
                    pcmStereo[i * 2]     = pcmMono[i];
                    pcmStereo[i * 2 + 1] = pcmMono[i];
                }
                encoded = encodeInterleaved(handle, pcmStereo, readSamples, mp3Buf);
            }

            if (encoded > 0) {
                try {
                    outputStream.write(mp3Buf, 0, encoded);
                } catch (IOException e) {
                    sendError("Write failed: " + e.getMessage());
                    isRecording.set(false);
                    break;
                }
            } else if (encoded < 0) {
                sendError("LAME encode error: " + encoded);
            }
        }
        // Worker thread exits here; stop() / teardown complete the cleanup.
    }

    // ─────────────────────────────────────────────────────────────────────
    // pause()
    // ─────────────────────────────────────────────────────────────────────

    private void handlePause(Result result) {
        if (!isRecording.get() || isPaused.get()) {
            replyBool(result, false);
            return;
        }
        isPaused.set(true);
        // Stop AudioRecord so read() returns immediately; worker enters wait().
        audioRecord.stop();
        replyBool(result, true);
        sendStatus(STATUS_PAUSED);
    }

    // ─────────────────────────────────────────────────────────────────────
    // resume()
    // ─────────────────────────────────────────────────────────────────────

    private void handleResume(Result result) {
        if (!isRecording.get() || !isPaused.get()) {
            replyBool(result, false);
            return;
        }
        audioRecord.startRecording();
        isPaused.set(false);
        synchronized (pauseLock) {
            pauseLock.notifyAll();
        }
        replyBool(result, true);
        sendStatus(STATUS_RECORDING);
    }

    // ─────────────────────────────────────────────────────────────────────
    // stop()
    // ─────────────────────────────────────────────────────────────────────

    private void handleStop(Result result) {
        if (!isRecording.get()) {
            replyNull(result);
            return;
        }
        final String path = stopRecordingInternal();
        replyString(result, path);
        sendStatus(STATUS_IDLE);
    }

    /**
     * Core teardown sequence shared by handleStop() and onDetachedFromEngine().
     *
     * <ol>
     *   <li>Clear {@code isRecording} so the worker loop exits.</li>
     *   <li>Stop AudioRecord (unblocks any pending read()).</li>
     *   <li>Wake the worker if it is paused.</li>
     *   <li>Join the worker thread (no timeout).</li>
     *   <li>Flush LAME, write flushed bytes, close encoder, close stream.</li>
     *   <li>Release AudioRecord.</li>
     * </ol>
     *
     * @return the output file path, or {@code null} on error.
     */
    private String stopRecordingInternal() {
        isRecording.set(false);

        // Unblock AudioRecord.read() if currently capturing.
        if (audioRecord != null) {
            try { audioRecord.stop(); } catch (IllegalStateException ignored) {}
        }

        // Wake the worker thread if it is waiting in the pause gate.
        synchronized (pauseLock) {
            pauseLock.notifyAll();
        }

        // Wait for the worker to finish (no timeout — guaranteed to terminate
        // because isRecording is now false and AudioRecord.stop() was called).
        if (workerThread != null) {
            try {
                workerThread.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            workerThread = null;
        }

        // Flush remaining LAME frames.
        if (lameHandle != 0L && outputStream != null) {
            try {
                final int mp3FlushBufSize = 7200;
                final byte[] flushBuf     = new byte[mp3FlushBufSize];
                int flushed = flush(lameHandle, flushBuf);
                if (flushed > 0) {
                    outputStream.write(flushBuf, 0, flushed);
                }
            } catch (IOException e) {
                sendError("Flush write failed: " + e.getMessage());
            }
        }

        // Close the LAME encoder.
        if (lameHandle != 0L) {
            closeEncoder(lameHandle);
            lameHandle = 0L;
        }

        // Close the output stream.
        if (outputStream != null) {
            try {
                outputStream.flush();
                outputStream.close();
            } catch (IOException ignored) {}
            outputStream = null;
        }

        // Release AudioRecord resources.
        if (audioRecord != null) {
            audioRecord.release();
            audioRecord = null;
        }

        final String path = outputFilePath;
        outputFilePath = null;
        isPaused.set(false);
        return path;
    }

    // ─────────────────────────────────────────────────────────────────────
    // EventSink helpers — always called on the main thread
    // ─────────────────────────────────────────────────────────────────────

    private void sendStatus(String value) {
        mainHandler.post(() -> {
            if (eventSink == null) return;
            final Map<String, String> event = new HashMap<>();
            event.put("type",  "status");
            event.put("value", value);
            eventSink.success(event);
        });
    }

    private void sendError(String message) {
        mainHandler.post(() -> {
            if (eventSink == null) return;
            final Map<String, String> event = new HashMap<>();
            event.put("type",    "error");
            event.put("message", message);
            eventSink.success(event);
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // Result helpers — always posted on the main thread
    // ─────────────────────────────────────────────────────────────────────

    private void replyBool(Result result, boolean value) {
        mainHandler.post(() -> result.success(value));
    }

    private void replyString(Result result, String value) {
        mainHandler.post(() -> result.success(value));
    }

    private void replyNull(Result result) {
        mainHandler.post(() -> result.success(null));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Utility
    // ─────────────────────────────────────────────────────────────────────

    /** Safely casts an Object (Integer or null) to int, falling back to defaultValue. */
    private static int toInt(Object value, int defaultValue) {
        if (value instanceof Integer) return (Integer) value;
        if (value instanceof Long)    return ((Long) value).intValue();
        return defaultValue;
    }
}
