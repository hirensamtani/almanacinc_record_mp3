import 'package:almanacinc_record_mp3/almanacinc_record_mp3.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> log;
  String? currentRecordingPath;

  setUp(() {
    log = [];
    currentRecordingPath = null;

    // 1. Mock MethodChannel
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.almanacinc.record_mp3'),
          (MethodCall call) async {
        log.add(call);
        switch (call.method) {
          case 'hasPermission':
            return true;
          case 'start':
            if (call.arguments is Map) {
              currentRecordingPath = call.arguments['filePath'] as String?;
            }
            // Emit recording status via EventChannel mock so instance.status transitions
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .handlePlatformMessage(
              'com.almanacinc.record_mp3/events',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'type': 'status',
                'value': 'recording',
              }),
                  (_) {},
            );
            return true;
          case 'pause':
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .handlePlatformMessage(
              'com.almanacinc.record_mp3/events',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'type': 'status',
                'value': 'paused',
              }),
                  (_) {},
            );
            return true;
          case 'resume':
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .handlePlatformMessage(
              'com.almanacinc.record_mp3/events',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'type': 'status',
                'value': 'recording',
              }),
                  (_) {},
            );
            return true;
          case 'stop':
            final path = currentRecordingPath ?? '/tmp/out.mp3';
            currentRecordingPath = null;
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .handlePlatformMessage(
              'com.almanacinc.record_mp3/events',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'type': 'status',
                'value': 'idle',
              }),
                  (_) {},
            );
            return path;
          default:
            return null;
        }
      },
    );

    // 2. Mock EventChannel stream listener
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('com.almanacinc.record_mp3/events'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {},
        onCancel: (arguments) {},
      ),
    );
  });

  tearDown(() async {
    // Reset singleton status if left active
    if (AlmanacRecordMp3.instance.status != AlmanacRecordMp3Status.idle) {
      await AlmanacRecordMp3.instance.stop();
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.almanacinc.record_mp3'),
      null,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('com.almanacinc.record_mp3/events'),
      null,
    );
  });

  group('AlmanacRecordMp3 – parameter validation', () {
    test('throws ArgumentError for invalid sampleRate', () {
      expect(
            () => AlmanacRecordMp3.instance.start('/tmp/out.mp3', sampleRate: 8000),
        throwsA(
          isA<ArgumentError>().having(
                (e) => e.name,
            'name',
            'sampleRate',
          ),
        ),
      );
    });

    test('throws ArgumentError for invalid bitRate', () {
      expect(
            () => AlmanacRecordMp3.instance.start('/tmp/out.mp3', bitRate: 999),
        throwsA(
          isA<ArgumentError>().having(
                (e) => e.name,
            'name',
            'bitRate',
          ),
        ),
      );
    });

    test('throws ArgumentError for invalid numChannels', () {
      expect(
            () => AlmanacRecordMp3.instance.start('/tmp/out.mp3', numChannels: 3),
        throwsA(
          isA<ArgumentError>().having(
                (e) => e.name,
            'name',
            'numChannels',
          ),
        ),
      );
    });

    test('accepts all valid sampleRate values without throwing', () async {
      const validRates = [16000, 22050, 44100, 48000];
      for (final rate in validRates) {
        expect(
              () => AlmanacRecordMp3.instance.start(
            '/tmp/out.mp3',
            sampleRate: rate,
          ),
          returnsNormally,
        );
        await AlmanacRecordMp3.instance.stop();
      }
    });

    test('accepts all valid bitRate values without throwing', () async {
      const validRates = [32, 48, 64, 96, 128, 160, 192, 256, 320];
      for (final rate in validRates) {
        expect(
              () => AlmanacRecordMp3.instance.start(
            '/tmp/out.mp3',
            bitRate: rate,
          ),
          returnsNormally,
        );
        await AlmanacRecordMp3.instance.stop();
      }
    });

    test('accepts numChannels 1 and 2 without throwing', () async {
      for (final ch in [1, 2]) {
        expect(
              () => AlmanacRecordMp3.instance.start(
            '/tmp/out.mp3',
            numChannels: ch,
          ),
          returnsNormally,
        );
        await AlmanacRecordMp3.instance.stop();
      }
    });
  });

  group('AlmanacRecordMp3 – initial state', () {
    test('status starts as idle', () {
      expect(
        AlmanacRecordMp3.instance.status,
        AlmanacRecordMp3Status.idle,
      );
    });

    test('onStatusChanged is a broadcast stream', () {
      expect(
        AlmanacRecordMp3.instance.onStatusChanged.isBroadcast,
        isTrue,
      );
    });

    test('onError is a broadcast stream', () {
      expect(
        AlmanacRecordMp3.instance.onError.isBroadcast,
        isTrue,
      );
    });
  });

  group('AlmanacRecordMp3 – state-machine guards & custom paths', () {
    test('stop returns null when status is idle', () async {
      final result = await AlmanacRecordMp3.instance.stop();
      expect(result, isNull);
    });

    test('hasPermission invokes hasPermission on native channel', () async {
      final result = await AlmanacRecordMp3.instance.hasPermission();
      expect(result, isTrue);
      expect(log.last.method, 'hasPermission');
    });

    test('pause returns false when idle', () async {
      final logBefore = log.length;
      final result = await AlmanacRecordMp3.instance.pause();
      expect(result, isFalse);
      expect(log.length, logBefore);
    });

    test('resume returns false when idle', () async {
      final logBefore = log.length;
      final result = await AlmanacRecordMp3.instance.resume();
      expect(result, isFalse);
      expect(log.length, logBefore);
    });

    test('start passes exact custom path and filename', () async {
      const customPath = '/custom/directory/my_custom_take_101.mp3';
      final started = await AlmanacRecordMp3.instance.start(customPath);
      expect(started, isTrue);

      final startCall = log.firstWhere((call) => call.method == 'start');
      expect(startCall.arguments['filePath'], customPath);

      final stoppedPath = await AlmanacRecordMp3.instance.stop();
      expect(stoppedPath, equals(customPath));
    });
  });

  group('AlmanacRecordMp3Status – enum coverage', () {
    test('all status values are defined', () {
      expect(AlmanacRecordMp3Status.values, hasLength(3));
      expect(
        AlmanacRecordMp3Status.values,
        containsAll([
          AlmanacRecordMp3Status.idle,
          AlmanacRecordMp3Status.recording,
          AlmanacRecordMp3Status.paused,
        ]),
      );
    });
  });
}