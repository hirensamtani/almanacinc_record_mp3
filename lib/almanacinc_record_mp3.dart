/// A Flutter plugin for real-time MP3 recording using the vendored LAME 3.100
/// encoder.
///
/// Raw 16-bit PCM is captured from the device microphone and encoded
/// **directly** into MP3 frames — no intermediate WAV file, no post-conversion
/// pass. Encoding uses Constant Bit Rate (CBR) mode.
///
/// ## Quick start
///
/// ```dart
/// final recorder = AlmanacRecordMp3.instance;
///
/// // Request microphone permission
/// if (!await recorder.hasPermission()) return;
///
/// // Start recording
/// await recorder.start(
///   '/path/to/output.mp3',
///   sampleRate: 44100,
///   bitRate: 128,
///   numChannels: 1,
/// );
///
/// // Later…
/// final path = await recorder.stop();
/// ```
///
/// See [AlmanacRecordMp3] for the full API.
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// Represents the current recording lifecycle state.
enum AlmanacRecordMp3Status {
  /// No recording is active. The encoder is closed and no file is open.
  idle,

  /// Actively capturing audio and encoding MP3 frames to disk.
  recording,

  /// Recording is paused. The encoder and output file remain open.
  paused,
}

/// Real-time MP3 recorder backed by the vendored LAME 3.100 C library.
///
/// Access via the [instance] singleton. Do not construct this class directly.
///
/// ### Lifecycle
///
/// ```
/// idle ──start()──▶ recording ──pause()──▶ paused
///                      ▲                     │
///                      └────resume()──────────┘
///       ◀──stop()──────────────────────────────
/// ```
///
/// ### Parameter validation
///
/// Parameters passed to [start] are validated before calling native code:
///
/// | Parameter     | Valid values                               |
/// |---------------|--------------------------------------------|
/// | `sampleRate`  | 16000, 22050, 44100, 48000                 |
/// | `numChannels` | 1, 2                                       |
/// | `bitRate`     | 32, 48, 64, 96, 128, 160, 192, 256, 320   |
///
/// An [ArgumentError] is thrown for values outside the listed sets.
class AlmanacRecordMp3 {
  AlmanacRecordMp3._();

  // ─────────────────────────── Singleton ───────────────────────────────────

  static final AlmanacRecordMp3 _instance = AlmanacRecordMp3._();

  /// The singleton instance of [AlmanacRecordMp3].
  static AlmanacRecordMp3 get instance => _instance;

  // ─────────────────────────── Channels ────────────────────────────────────

  static const MethodChannel _methodChannel =
      MethodChannel('com.almanacinc.record_mp3');

  static const EventChannel _eventChannel =
      EventChannel('com.almanacinc.record_mp3/events');

  // ─────────────────────────── State ───────────────────────────────────────

  /// The current synchronous recording status.
  ///
  /// Updated whenever a status event is received from the native layer.
  AlmanacRecordMp3Status get status => _status;
  AlmanacRecordMp3Status _status = AlmanacRecordMp3Status.idle;

  // ─────────────────────────── Streams ─────────────────────────────────────

  StreamSubscription<dynamic>? _eventSubscription;
  StreamSubscription<String>? _onErrorStopSub;

  final StreamController<AlmanacRecordMp3Status> _statusController =
      StreamController<AlmanacRecordMp3Status>.broadcast();

  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  /// A broadcast stream that emits a new [AlmanacRecordMp3Status] every time
  /// the recording state changes.
  Stream<AlmanacRecordMp3Status> get onStatusChanged =>
      _statusController.stream;

  /// A broadcast stream that emits error message strings from the native layer.
  ///
  /// Errors are also forwarded to the `onError` callback supplied to [start],
  /// which is automatically cancelled when [stop] is called.
  Stream<String> get onError => _errorController.stream;

  // ─────────────────────────── Valid parameter sets ─────────────────────────

  static const Set<int> _validSampleRates = {16000, 22050, 44100, 48000};
  static const Set<int> _validBitRates = {
    32,
    48,
    64,
    96,
    128,
    160,
    192,
    256,
    320,
  };
  static const Set<int> _validChannels = {1, 2};

  // ─────────────────────────── Internal helpers ─────────────────────────────

  /// Ensure the native event stream is subscribed.
  void _ensureEventSubscription() {
    _eventSubscription ??= _eventChannel
        .receiveBroadcastStream()
        .listen(_handleNativeEvent, onError: _handleStreamError);
  }

  void _handleNativeEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'status':
        final value = event['value'] as String?;
        final newStatus = _parseStatus(value);
        if (newStatus != null) {
          _status = newStatus;
          _statusController.add(newStatus);
        }
      case 'error':
        final message = event['message'] as String? ?? 'Unknown error';
        _errorController.add(message);
    }
  }

  void _handleStreamError(Object error) {
    _errorController.add(error.toString());
  }

  AlmanacRecordMp3Status? _parseStatus(String? value) {
    switch (value) {
      case 'idle':
        return AlmanacRecordMp3Status.idle;
      case 'recording':
        return AlmanacRecordMp3Status.recording;
      case 'paused':
        return AlmanacRecordMp3Status.paused;
      default:
        return null;
    }
  }

  // ─────────────────────────── Public API ──────────────────────────────────

  /// Requests the microphone permission if it has not yet been determined.
  ///
  /// Returns `true` if the app has (or is granted) the microphone permission,
  /// `false` if the user denies it.
  ///
  /// On Android this calls the `RECORD_AUDIO` runtime permission flow.
  /// On iOS this calls `AVAudioSession.requestRecordPermission`.
  Future<bool> hasPermission() async {
    try {
      final result =
          await _methodChannel.invokeMethod<bool>('hasPermission') ?? false;
      return result;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'hasPermission failed');
      return false;
    }
  }

  /// Begins recording to [filePath].
  ///
  /// Returns `true` if recording started successfully, `false` if:
  /// - recording is already active (not [AlmanacRecordMp3Status.idle])
  /// - permission was denied
  /// - the native layer failed to open/initialise the encoder
  ///
  /// Throws [ArgumentError] if any parameter is outside the allowed set.
  ///
  /// [filePath] – Absolute path to the output `.mp3` file. The parent
  ///   directory must already exist.
  ///
  /// [sampleRate] – Output sample rate in Hz. Must be one of
  ///   `{16000, 22050, 44100, 48000}`. Defaults to `44100`.
  ///
  /// [bitRate] – CBR bit rate in kbps. Must be one of
  ///   `{32, 48, 64, 96, 128, 160, 192, 256, 320}`. Defaults to `128`.
  ///
  /// [numChannels] – Number of output channels. Must be `1` (mono) or `2`
  ///   (stereo). Defaults to `1`.
  ///
  /// [onError] – Optional callback invoked with each error message emitted
  ///   during the recording session. The subscription is cancelled when [stop]
  ///   is called.
  Future<bool> start(
    String filePath, {
    int sampleRate = 44100,
    int bitRate = 128,
    int numChannels = 1,
    void Function(String error)? onError,
  }) async {
    // --- Dart-side validation ---
    if (!_validSampleRates.contains(sampleRate)) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'Must be one of $_validSampleRates',
      );
    }
    if (!_validBitRates.contains(bitRate)) {
      throw ArgumentError.value(
        bitRate,
        'bitRate',
        'Must be one of $_validBitRates',
      );
    }
    if (!_validChannels.contains(numChannels)) {
      throw ArgumentError.value(
        numChannels,
        'numChannels',
        'Must be one of $_validChannels',
      );
    }

    // Non-throwing state guard
    if (_status != AlmanacRecordMp3Status.idle) return false;

    _ensureEventSubscription();

    if (onError != null) {
      _onErrorStopSub = _errorController.stream.listen(onError);
    }

    try {
      final result = await _methodChannel.invokeMethod<bool>('start', {
            'filePath': filePath,
            'sampleRate': sampleRate,
            'bitRate': bitRate,
            'numChannels': numChannels,
          }) ??
          false;
      return result;
    } on PlatformException catch (e) {
      final message = e.message ?? 'start failed';
      _errorController.add(message);
      _onErrorStopSub?.cancel();
      _onErrorStopSub = null;
      return false;
    }
  }

  /// Pauses an active recording.
  ///
  /// The LAME encoder and the output file remain open during the pause.
  /// Audio capture is suspended on the native side.
  ///
  /// Returns `true` if the pause was accepted, `false` if the current
  /// [status] is not [AlmanacRecordMp3Status.recording].
  Future<bool> pause() async {
    if (_status != AlmanacRecordMp3Status.recording) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('pause') ?? false;
      return result;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'pause failed');
      return false;
    }
  }

  /// Resumes a paused recording.
  ///
  /// Audio capture and encoding restart on the same encoder handle and output
  /// file that were active before [pause] was called.
  ///
  /// Returns `true` if the resume was accepted, `false` if the current
  /// [status] is not [AlmanacRecordMp3Status.paused].
  Future<bool> resume() async {
    if (_status != AlmanacRecordMp3Status.paused) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('resume') ?? false;
      return result;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'resume failed');
      return false;
    }
  }

  /// Stops recording, flushes remaining LAME frames, and closes the output
  /// file.
  ///
  /// Returns the absolute path to the completed `.mp3` file, or `null` if the
  /// recorder is currently [AlmanacRecordMp3Status.idle] or if an error
  /// occurred during finalization.
  ///
  /// The `onError` subscription registered in [start] is cancelled after this
  /// call regardless of outcome.
  Future<String?> stop() async {
    if (_status == AlmanacRecordMp3Status.idle) return null;

    _onErrorStopSub?.cancel();
    _onErrorStopSub = null;

    try {
      final result = await _methodChannel.invokeMethod<String>('stop');
      return result;
    } on PlatformException catch (e) {
      _errorController.add(e.message ?? 'stop failed');
      return null;
    }
  }
}
