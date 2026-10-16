// Copyright (c) 2024 Almanac Inc. — MIT License
// See LICENSE at the repository root for full text.

import AVFoundation
import Flutter

// MARK: - SwiftAlmanacRecordMp3Plugin

/// iOS Swift implementation of the `almanacinc_record_mp3` Flutter plugin.
///
/// ## Architecture
///
/// ```
/// Microphone
///    │
///    ▼  (hardware format — matches inputNode.outputFormat)
/// AVAudioEngine tap (bufferSize: 4096)
///    │
///    ▼  (AVAudioConverter → interleaved int16 PCM at requested rate/channels)
/// encodingQueue (serial DispatchQueue)
///    │
///    ▼  (AlmanacLame C wrapper → vendored LAME 3.100)
/// MP3 frames → FileHandle (output.mp3)
/// ```
///
/// - All LAME encoding and file I/O happen exclusively on `encodingQueue`.
/// - All state mutations and Flutter result/event calls happen on the main thread.
/// - Pause = `engine.pause()`. Resume = `engine.start()`. Neither closes the
///   encoder handle or the output file.
/// - Stop removes the tap, stops the engine, then drains `encodingQueue`
///   synchronously (via `queue.sync`) before flushing LAME and closing resources.
public final class SwiftAlmanacRecordMp3Plugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Registration

    /// Registers the plugin with the Flutter engine.
    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.almanacinc.record_mp3",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.almanacinc.record_mp3/events",
            binaryMessenger: registrar.messenger()
        )
        let instance = SwiftAlmanacRecordMp3Plugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - Internal state types

    private enum RecordingState {
        case idle, recording, paused
    }

    // MARK: - Flutter sink

    /// Set by `onListen`, cleared by `onCancel`. Only read on the main thread.
    private var eventSink: FlutterEventSink?

    // MARK: - Recording lifecycle state

    /// Mutated only on the main thread.
    private var recordingState: RecordingState = .idle

    // MARK: - Audio graph

    private let engine = AVAudioEngine()

    /// Converts from the hardware input format to the requested target format.
    /// Rebuilt on route/configuration changes without closing the encoder.
    private var converter: AVAudioConverter?

    /// Target format: interleaved Int16 PCM at the requested sample rate and channels.
    private var targetFormat: AVAudioFormat?

    // MARK: - Session configuration (written on start, cleared on stop)

    private var configuredSampleRate: Int = 44100
    private var configuredChannels:   Int = 1
    private var configuredBitRate:    Int = 128

    // MARK: - LAME handle and file (ONLY accessed from encodingQueue)

    /// Opaque handle returned by `AlmanacLameInit`. Accessed only on `encodingQueue`.
    private var lameHandle:    UnsafeMutableRawPointer? = nil

    /// Open file handle for the output `.mp3` file. Accessed only on `encodingQueue`.
    private var outputFile:    FileHandle? = nil

    /// Absolute path to the output file. Written on the main thread before the
    /// queue is started; read after `encodingQueue.sync` completes on stop.
    private var outputFilePath: String? = nil

    // MARK: - Serial encoding queue

    /// All LAME calls and `FileHandle.write(_:)` happen here exclusively.
    private let encodingQueue = DispatchQueue(
        label: "com.almanacinc.record_mp3.encoding",
        qos: .userInitiated
    )

    // MARK: - Notification observer tokens

    private var interruptionToken:  NSObjectProtocol?
    private var routeChangeToken:   NSObjectProtocol?
    private var configChangeToken:  NSObjectProtocol?

    // MARK: - Dealloc

    deinit {
        unsubscribeNotifications()
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - FlutterPlugin / MethodCallHandler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasPermission":
            handleHasPermission(result: result)
        case "start":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Expected [String: Any] argument map",
                    details: nil
                ))
                return
            }
            handleStart(args: args, result: result)
        case "pause":
            handlePause(result: result)
        case "resume":
            handleResume(result: result)
        case "stop":
            handleStop(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - hasPermission

    private func handleHasPermission(result: @escaping FlutterResult) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { result(granted) }
        }
    }

    // MARK: - start

    private func handleStart(args: [String: Any], result: @escaping FlutterResult) {
        guard recordingState == .idle else {
            result(false)
            return
        }

        guard let filePath = args["filePath"] as? String, !filePath.isEmpty else {
            sendError("filePath is null or empty")
            result(false)
            return
        }

        let sampleRate  = args["sampleRate"]  as? Int ?? 44100
        let bitRate     = args["bitRate"]     as? Int ?? 128
        let numChannels = args["numChannels"] as? Int ?? 1

        // Validate parent directory
        let parentPath = (filePath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        let parentExists = FileManager.default.fileExists(
            atPath: parentPath, isDirectory: &isDir
        )
        guard parentExists && isDir.boolValue else {
            sendError("Parent directory does not exist: \(parentPath)")
            result(false)
            return
        }
        guard FileManager.default.isWritableFile(atPath: parentPath) else {
            sendError("Parent directory is not writable: \(parentPath)")
            result(false)
            return
        }

        // Request microphone permission before touching AVAudioSession
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    self.sendError("Microphone permission denied")
                    result(false)
                    return
                }
                self.beginRecordingSession(
                    filePath: filePath,
                    sampleRate: sampleRate,
                    bitRate: bitRate,
                    numChannels: numChannels,
                    result: result
                )
            }
        }
    }

    // Runs on main thread (called from the requestRecordPermission callback).
    private func beginRecordingSession(
        filePath: String,
        sampleRate: Int,
        bitRate: Int,
        numChannels: Int,
        result: @escaping FlutterResult
    ) {
        // ── 1. Configure AVAudioSession ──────────────────────────────────
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            sendError("AVAudioSession setup failed: \(error.localizedDescription)")
            result(false)
            return
        }

        // ── 2. Build target format: interleaved int16 PCM ─────────────────
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(numChannels),
            interleaved: true
        ) else {
            sendError("Failed to build target AVAudioFormat")
            result(false)
            return
        }

        // ── 3. Query hardware input format (tap MUST use this format) ──────
        let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)

        // ── 4. Build AVAudioConverter: hardware format → target format ─────
        guard let conv = AVAudioConverter(from: hardwareFormat, to: target) else {
            sendError("Failed to create AVAudioConverter")
            result(false)
            return
        }

        // ── 5. Open output file ───────────────────────────────────────────
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: filePath) else {
            sendError("Cannot open output file: \(filePath)")
            result(false)
            return
        }
        fh.truncateFile(atOffset: 0)

        // ── 6. Initialise LAME (synchronous on encodingQueue) ─────────────
        var lame: UnsafeMutableRawPointer? = nil
        encodingQueue.sync {
            lame = AlmanacLameInit(
                Int32(sampleRate),
                Int32(numChannels),
                Int32(bitRate)
            )
        }
        guard let validLame = lame else {
            fh.closeFile()
            sendError("AlmanacLameInit failed")
            result(false)
            return
        }

        // ── 7. Commit session state ───────────────────────────────────────
        converter            = conv
        targetFormat         = target
        lameHandle           = validLame
        outputFile           = fh
        outputFilePath       = filePath
        configuredSampleRate = sampleRate
        configuredChannels   = numChannels
        configuredBitRate    = bitRate

        // ── 8. Install tap and start engine ───────────────────────────────
        installTap(hardwareFormat: hardwareFormat)

        do {
            try engine.start()
        } catch {
            removeTap()
            // Clean up LAME and file on engine-start failure
            encodingQueue.sync {
                AlmanacLameClose(validLame)
                self.lameHandle = nil
            }
            fh.closeFile()
            outputFile       = nil
            outputFilePath   = nil
            sendError("AVAudioEngine.start() failed: \(error.localizedDescription)")
            result(false)
            return
        }

        // ── 9. Activate observers and update state ────────────────────────
        recordingState = .recording
        subscribeNotifications()
        result(true)
        sendStatus("recording")
    }

    // MARK: - Tap management

    private func installTap(hardwareFormat: AVAudioFormat) {
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: hardwareFormat
        ) { [weak self] buffer, _ in
            self?.tapCallback(buffer: buffer, hardwareFormat: hardwareFormat)
        }
    }

    private func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Called on the audio engine's internal render thread. Converts the
    /// hardware buffer to interleaved int16 PCM and dispatches encoding to
    /// `encodingQueue`.  The converted PCM is copied into a value-type array
    /// before dispatch so the AVAudioPCMBuffer can be safely recycled.
    private func tapCallback(buffer: AVAudioPCMBuffer, hardwareFormat: AVAudioFormat) {
        guard let conv   = converter,
              let target = targetFormat else { return }

        // Compute output frame capacity (may differ due to sample-rate conversion)
        let ratio       = target.sampleRate / hardwareFormat.sampleRate
        let outCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up) + 1
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: outCapacity
        ) else { return }

        // Convert: hardware format → interleaved int16 PCM at target rate/channels
        var convError: NSError?
        var inputConsumed = false
        let status = conv.convert(
            to: outputBuffer,
            error: &convError
        ) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed          = true
            outStatus.pointee      = .haveData
            return buffer
        }

        guard status != .error,
              convError == nil,
              outputBuffer.frameLength > 0
        else { return }

        // Copy interleaved samples into a Swift array before leaving the tap.
        // For an interleaved AVAudioPCMBuffer, int16ChannelData[0] holds ALL
        // interleaved samples (L0 R0 L1 R1 … for stereo).
        guard let int16Ptr = outputBuffer.int16ChannelData else { return }
        let frameCount   = Int(outputBuffer.frameLength)
        let channelCount = Int(target.channelCount)
        let totalSamples = frameCount * channelCount
        var pcmCopy      = [Int16](repeating: 0, count: totalSamples)
        for i in 0 ..< totalSamples { pcmCopy[i] = int16Ptr[0][i] }

        let channels = configuredChannels
        encodingQueue.async { [weak self] in
            self?.encodeAndWrite(pcm: pcmCopy, frameCount: frameCount, numChannels: channels)
        }
    }

    // MARK: - Encoding (runs exclusively on encodingQueue)

    private func encodeAndWrite(pcm: [Int16], frameCount: Int, numChannels: Int) {
        guard let lame = lameHandle,
              let fh   = outputFile else { return }

        let mp3BufSize = 7200 + Int(1.25 * Double(frameCount))
        var mp3Buf     = [UInt8](repeating: 0, count: mp3BufSize)

        let encoded: Int32 = pcm.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return -1 }
            if numChannels == 1 {
                return AlmanacLameEncode(
                    lame,
                    base,
                    Int32(frameCount),
                    &mp3Buf,
                    Int32(mp3BufSize)
                )
            } else {
                // pcm is already interleaved (L0 R0 L1 R1 …) from the converter
                return AlmanacLameEncodeInterleaved(
                    lame,
                    base,
                    Int32(frameCount),
                    &mp3Buf,
                    Int32(mp3BufSize)
                )
            }
        }

        if encoded > 0 {
            fh.write(Data(bytes: mp3Buf, count: Int(encoded)))
        } else if encoded < 0 {
            let code = encoded
            DispatchQueue.main.async { [weak self] in
                self?.sendError("LAME encode error: \(code)")
            }
        }
    }

    // MARK: - pause

    private func handlePause(result: @escaping FlutterResult) {
        guard recordingState == .recording else {
            result(false)
            return
        }
        // Pause the engine; the tap remains installed and the encoder/file stay open.
        engine.pause()
        recordingState = .paused
        result(true)
        sendStatus("paused")
    }

    // MARK: - resume

    private func handleResume(result: @escaping FlutterResult) {
        guard recordingState == .paused else {
            result(false)
            return
        }
        do {
            // Restart the engine on the same encoder handle and file.
            try engine.start()
            recordingState = .recording
            result(true)
            sendStatus("recording")
        } catch {
            sendError("AVAudioEngine resume failed: \(error.localizedDescription)")
            result(false)
        }
    }

    // MARK: - stop

    private func handleStop(result: @escaping FlutterResult) {
        guard recordingState != .idle else {
            result(nil)
            return
        }
        let path = stopSession()
        result(path)
        sendStatus("idle")
    }

    /// Teardown sequence (always called on the main thread):
    ///
    /// 1. Mark state as idle and remove notification observers.
    /// 2. Remove tap and stop engine.
    /// 3. `encodingQueue.sync` — drains all pending work, then flushes LAME,
    ///    writes flushed bytes, closes encoder, closes file handle.
    /// 4. Deactivate `AVAudioSession` with `.notifyOthersOnDeactivation`.
    /// 5. Clear state properties and return the output path.
    @discardableResult
    private func stopSession() -> String? {
        recordingState = .idle
        unsubscribeNotifications()

        // Remove tap and stop the audio engine (unblocks any in-flight render).
        removeTap()
        engine.stop()

        // Drain the encoding queue synchronously, then flush and close.
        encodingQueue.sync {
            guard let lame = self.lameHandle else { return }

            // Flush remaining internal LAME frames (e.g., trailing silence padding).
            let flushBufSize = 7200
            var flushBuf = [UInt8](repeating: 0, count: flushBufSize)
            let flushed  = AlmanacLameFlush(lame, &flushBuf, Int32(flushBufSize))
            if flushed > 0, let fh = self.outputFile {
                fh.write(Data(bytes: flushBuf, count: Int(flushed)))
            }

            // Close LAME encoder.
            AlmanacLameClose(lame)
            self.lameHandle = nil

            // Close the output file.
            self.outputFile?.closeFile()
            self.outputFile = nil
        }

        // Deactivate the audio session, notifying other apps they may resume.
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            // Non-fatal — audio session may already be inactive.
        }

        // Clear remaining state.
        converter      = nil
        targetFormat   = nil
        let path       = outputFilePath
        outputFilePath = nil
        return path
    }

    // MARK: - Notification management

    private func subscribeNotifications() {
        let nc = NotificationCenter.default

        interruptionToken = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] n in self?.onInterruption(n) }

        routeChangeToken = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] n in self?.onRouteChange(n) }

        configChangeToken = nc.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in self?.onEngineConfigurationChange() }
    }

    private func unsubscribeNotifications() {
        let nc = NotificationCenter.default
        [interruptionToken, routeChangeToken, configChangeToken]
            .compactMap { $0 }
            .forEach { nc.removeObserver($0) }
        interruptionToken = nil
        routeChangeToken  = nil
        configChangeToken = nil
    }

    // MARK: - AVAudioSession interruption

    private func onInterruption(_ notification: Notification) {
        guard
            let info    = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type    = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            // Automatically pause when an interruption begins (e.g. phone call).
            if recordingState == .recording {
                engine.pause()
                recordingState = .paused
                sendStatus("paused")
            }
        case .ended:
            // Per spec: do NOT auto-resume; leave the app in the paused state.
            // The user must call resume() explicitly.
            break
        @unknown default:
            break
        }
    }

    // MARK: - AVAudioSession route change

    private func onRouteChange(_ notification: Notification) {
        guard
            let info      = notification.userInfo,
            let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason    = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        // Act ONLY on device availability changes; ignore category changes,
        // wake-from-sleep, overrides, and all other reasons.
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            guard recordingState == .recording || recordingState == .paused else { return }
            rebuildTap()
        default:
            break
        }
    }

    // MARK: - AVAudioEngine configuration change

    private func onEngineConfigurationChange() {
        guard recordingState == .recording || recordingState == .paused else { return }
        rebuildTap()
    }

    // MARK: - Tap rebuild (encoder + file stay open)

    /// Rebuilds the `AVAudioConverter` and reinstalls the tap for the current
    /// hardware input format, without touching the LAME encoder or output file.
    ///
    /// If the engine restart fails, the state transitions to `.paused` and an
    /// error event is emitted.
    private func rebuildTap() {
        // Remove existing tap before querying the updated hardware format.
        removeTap()

        let newHardwareFormat = engine.inputNode.outputFormat(forBus: 0)

        guard
            let target  = targetFormat,
            let newConv = AVAudioConverter(from: newHardwareFormat, to: target)
        else {
            sendError("Could not rebuild AVAudioConverter after hardware change")
            recordingState = .paused
            sendStatus("paused")
            return
        }

        converter = newConv
        installTap(hardwareFormat: newHardwareFormat)

        // Only restart the engine if we were actively recording.
        guard recordingState == .recording else { return }

        do {
            try engine.start()
        } catch {
            sendError(
                "AVAudioEngine restart failed after hardware change: "
                + error.localizedDescription
            )
            recordingState = .paused
            sendStatus("paused")
        }
    }

    // MARK: - Event helpers (dispatch to main thread)

    private func sendStatus(_ value: String) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(["type": "status", "value": value])
        }
    }

    private func sendError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(["type": "error", "message": message])
        }
    }
}
