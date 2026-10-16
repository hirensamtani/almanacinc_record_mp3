// ignore_for_file: public_member_api_docs
import 'dart:async';

import 'package:almanacinc_record_mp3/almanacinc_record_mp3.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const RecordMp3ExampleApp());
}

class RecordMp3ExampleApp extends StatelessWidget {
  const RecordMp3ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Record MP3 Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const RecorderPage(),
    );
  }
}

class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key});

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage>
    with SingleTickerProviderStateMixin {
  final AlmanacRecordMp3 _recorder = AlmanacRecordMp3.instance;

  AlmanacRecordMp3Status _status = AlmanacRecordMp3Status.idle;
  String? _outputPath;
  Duration _elapsed = Duration.zero;

  // Stopwatch for UI elapsed-time display
  late final Ticker _ticker;
  DateTime? _recordingStart;
  Duration _pausedAccum = Duration.zero;
  DateTime? _pauseTime;

  // Subscriptions
  StreamSubscription<AlmanacRecordMp3Status>? _statusSub;
  StreamSubscription<String>? _errorSub;

  // Recording settings
  int _sampleRate = 44100;
  int _bitRate = 128;
  int _channels = 1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);

    _statusSub = _recorder.onStatusChanged.listen((s) {
      if (!mounted) return;
      setState(() {
        _status = s;
        if (s == AlmanacRecordMp3Status.recording && _recordingStart == null) {
          _recordingStart = DateTime.now();
          _ticker.start();
        }
        if (s == AlmanacRecordMp3Status.paused) {
          _pauseTime = DateTime.now();
          _ticker.stop();
        }
        if (s == AlmanacRecordMp3Status.recording && _pauseTime != null) {
          _pausedAccum += DateTime.now().difference(_pauseTime!);
          _pauseTime = null;
          _ticker.start();
        }
        if (s == AlmanacRecordMp3Status.idle) {
          _ticker.stop();
          _recordingStart = null;
          _pausedAccum = Duration.zero;
          _pauseTime = null;
          _elapsed = Duration.zero;
        }
      });
    });

    _errorSub = _recorder.onError.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $message'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  void _onTick(Duration _) {
    if (!mounted || _recordingStart == null) return;
    setState(() {
      _elapsed = DateTime.now().difference(_recordingStart!) - _pausedAccum;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _statusSub?.cancel();
    _errorSub?.cancel();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _start() async {
    setState(() {
      _outputPath = null;
    });

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission denied.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/recording_$timestamp.mp3';

    final started = await _recorder.start(
      path,
      sampleRate: _sampleRate,
      bitRate: _bitRate,
      numChannels: _channels,
    );

    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to start recording.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pause() async {
    await _recorder.pause();
  }

  Future<void> _resume() async {
    await _recorder.resume();
  }

  Future<void> _stop() async {
    final path = await _recorder.stop();
    if (mounted) {
      setState(() => _outputPath = path);
    }
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Color _statusColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (_status) {
      case AlmanacRecordMp3Status.idle:
        return cs.outline;
      case AlmanacRecordMp3Status.recording:
        return Colors.redAccent;
      case AlmanacRecordMp3Status.paused:
        return Colors.orangeAccent;
    }
  }

  IconData _statusIcon() {
    switch (_status) {
      case AlmanacRecordMp3Status.idle:
        return Icons.mic_none_rounded;
      case AlmanacRecordMp3Status.recording:
        return Icons.graphic_eq_rounded;
      case AlmanacRecordMp3Status.paused:
        return Icons.pause_circle_outline_rounded;
    }
  }

  String _statusLabel() {
    switch (_status) {
      case AlmanacRecordMp3Status.idle:
        return 'Idle';
      case AlmanacRecordMp3Status.recording:
        return 'Recording';
      case AlmanacRecordMp3Status.paused:
        return 'Paused';
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isIdle = _status == AlmanacRecordMp3Status.idle;
    final isPaused = _status == AlmanacRecordMp3Status.paused;

    return Scaffold(
      appBar: AppBar(
        title: const Text('almanacinc_record_mp3'),
        centerTitle: true,
        backgroundColor: cs.surfaceContainerHigh,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Status indicator ────────────────────────────────────────
              Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _statusColor(context).withValues(alpha: 0.12),
                    border: Border.all(
                      color: _statusColor(context),
                      width: 3,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Icon(
                          _statusIcon(),
                          key: ValueKey(_status),
                          size: 52,
                          color: _statusColor(context),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _statusLabel(),
                        style: TextStyle(
                          color: _statusColor(context),
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ── Timer ───────────────────────────────────────────────────
              Center(
                child: Text(
                  _formatDuration(_elapsed),
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w300,
                    color: isIdle ? cs.outlineVariant : cs.onSurface,
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // ── Settings (only when idle) ────────────────────────────────
              AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: isIdle ? 1.0 : 0.35,
                child: IgnorePointer(
                  ignoring: !isIdle,
                  child: Card(
                    elevation: 0,
                    color: cs.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Recording settings',
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(color: cs.primary),
                          ),
                          const SizedBox(height: 12),
                          _SettingRow(
                            label: 'Sample rate',
                            value: '$_sampleRate Hz',
                            onDecrement: () => setState(() {
                              const rates = [16000, 22050, 44100, 48000];
                              final i = rates.indexOf(_sampleRate);
                              if (i > 0) _sampleRate = rates[i - 1];
                            }),
                            onIncrement: () => setState(() {
                              const rates = [16000, 22050, 44100, 48000];
                              final i = rates.indexOf(_sampleRate);
                              if (i < rates.length - 1) {
                                _sampleRate = rates[i + 1];
                              }
                            }),
                          ),
                          _SettingRow(
                            label: 'Bit rate',
                            value: '$_bitRate kbps',
                            onDecrement: () => setState(() {
                              const rates = [
                                32,
                                48,
                                64,
                                96,
                                128,
                                160,
                                192,
                                256,
                                320,
                              ];
                              final i = rates.indexOf(_bitRate);
                              if (i > 0) _bitRate = rates[i - 1];
                            }),
                            onIncrement: () => setState(() {
                              const rates = [
                                32,
                                48,
                                64,
                                96,
                                128,
                                160,
                                192,
                                256,
                                320,
                              ];
                              final i = rates.indexOf(_bitRate);
                              if (i < rates.length - 1) {
                                _bitRate = rates[i + 1];
                              }
                            }),
                          ),
                          _SettingRow(
                            label: 'Channels',
                            value: _channels == 1 ? '1 (mono)' : '2 (stereo)',
                            onDecrement: () => setState(() => _channels = 1),
                            onIncrement: () => setState(() => _channels = 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── Control buttons ──────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Start
                  if (isIdle)
                    _CircleButton(
                      icon: Icons.fiber_manual_record_rounded,
                      color: Colors.redAccent,
                      size: 72,
                      onPressed: _start,
                      tooltip: 'Start recording',
                    ),

                  // Pause / Resume + Stop
                  if (!isIdle) ...[
                    _CircleButton(
                      icon: isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded,
                      color: Colors.orangeAccent,
                      size: 60,
                      onPressed: isPaused ? _resume : _pause,
                      tooltip: isPaused ? 'Resume' : 'Pause',
                    ),
                    const SizedBox(width: 24),
                    _CircleButton(
                      icon: Icons.stop_rounded,
                      color: cs.error,
                      size: 72,
                      onPressed: _stop,
                      tooltip: 'Stop recording',
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 32),

              // ── Output path ──────────────────────────────────────────────
              if (_outputPath != null)
                Card(
                  elevation: 0,
                  color: cs.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              color: cs.onSecondaryContainer,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Saved successfully',
                              style: TextStyle(
                                color: cs.onSecondaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _outputPath!,
                          style: TextStyle(
                            color: cs.onSecondaryContainer,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.color,
    required this.size,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(size),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.15),
            border: Border.all(color: color, width: 2.5),
          ),
          child: Icon(icon, color: color, size: size * 0.45),
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
  });

  final String label;
  final String value;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          IconButton.outlined(
            onPressed: onDecrement,
            icon: const Icon(Icons.remove, size: 18),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            onPressed: onIncrement,
            icon: const Icon(Icons.add, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
