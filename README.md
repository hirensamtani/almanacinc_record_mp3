# almanacinc_record_mp3

[![pub.dev](https://img.shields.io/pub/v/almanacinc_record_mp3.svg)](https://pub.dev/packages/almanacinc_record_mp3)
[![CI](https://github.com/hirensamtani/almanacinc_record_mp3/actions/workflows/ci.yml/badge.svg)](https://github.com/hirensamtani/almanacinc_record_mp3/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Flutter plugin for **real-time MP3 recording** on Android and iOS.

Raw 16-bit PCM is captured from the microphone and encoded **directly** into MP3 frames using the vendored **LAME 3.100** encoder — with no intermediate WAV file and no post-conversion pass.

---

## Features

| Feature | Detail |
|---|---|
| Encoding | CBR, 32–320 kbps |
| Channels | Mono (1) or Stereo (2) |
| Sample rates | 16 000 / 22 050 / 44 100 / 48 000 Hz |
| Custom Destinations | Save directly to any custom directory path and file name |
| Platforms | Android (API 21+) · iOS 12.0+ |
| Android ABI | armeabi-v7a · arm64-v8a · x86_64 |
| Page size | 16 KB aligned (Android 15/16 compatible) |
| Pause / Resume | Yes — encoder + file stay open |
| Background recording | Out of scope for 1.0.0 |

---

## Installation

Add `almanacinc_record_mp3` to your `pubspec.yaml`:

```yaml
dependencies:
  almanacinc_record_mp3: ^1.0.0
```

Then run:

```bash
flutter pub get
```

---

## Platform Setup

### Android

Add the `RECORD_AUDIO` permission to your app's `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
```

The plugin requests this permission at runtime; the manifest entry is still required by Android.

#### AGP Version Requirement (16 KB Page Size)

Your project must use **Android Gradle Plugin >= 8.5.1** to correctly package the 16 KB page-size-aligned shared library. Older AGP versions may repack the `.so` binary and break alignment, causing crashes on Android 15/16 devices with 16 KB page-size kernels.

Update your root `build.gradle`:

```groovy
classpath 'com.android.tools.build:gradle:8.5.1'
```

**Verification commands** (run after building a release APK):

```bash
# Verify APK zip-alignment at 16 KB
zipalign -c -P 16 -v 4 app.apk

# Verify LOAD segment alignment in the shared library (must show 2**14)
llvm-objdump -p libalmanac_record_mp3.so | grep LOAD
```

The LOAD segment alignment value must be `2**14` (= 16 384 bytes).

### iOS

Add the microphone usage description to your `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app requires microphone access to record audio.</string>
```

CocoaPods will compile the vendored LAME sources automatically — no manual framework setup is required.

---

## Quick Start

```dart
import 'dart:io';
import 'package:almanacinc_record_mp3/almanacinc_record_mp3.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

final recorder = AlmanacRecordMp3.instance;

// 1. Check or request microphone permission
final hasPermission = await recorder.hasPermission();
if (!hasPermission) return;

// 2. Define any custom directory path and file name
final directory = await getApplicationDocumentsDirectory();
final customDir = Directory('${directory.path}/my_vault');
if (!await customDir.exists()) {
  await customDir.create(recursive: true);
}

final outputPath = '${customDir.path}/take_${DateTime.now().millisecondsSinceEpoch}.mp3';

// 3. Start recording
final started = await recorder.start(
  outputPath,
  sampleRate: 44100,
  bitRate: 128,
  numChannels: 1,
  onError: (err) => debugPrint('Recording error: $err'),
);

// 4. Pause / Resume
await recorder.pause();
await recorder.resume();

// 5. Stop and get the output file path
final savedPath = await recorder.stop();
debugPrint('Saved to: $savedPath');
```

### Status Stream

```dart
recorder.onStatusChanged.listen((status) {
  switch (status) {
    case AlmanacRecordMp3Status.idle:
      debugPrint('Idle');
      break;
    case AlmanacRecordMp3Status.recording:
      debugPrint('Recording...');
      break;
    case AlmanacRecordMp3Status.paused:
      debugPrint('Paused');
      break;
  }
});
```

### Error Stream

```dart
recorder.onError.listen((message) {
  debugPrint('Error: $message');
});
```

---

## API Reference

### `AlmanacRecordMp3`

| Member | Description |
| --- | --- |
| `instance` | Singleton accessor |
| `status` | Current synchronous status (`idle`, `recording`, `paused`) |
| `onStatusChanged` | Broadcast stream of status changes |
| `onError` | Broadcast stream of error messages |
| `hasPermission()` | Request or check microphone permission |
| `start(path, ...)` | Begin recording to target path; returns `true` on success |
| `pause()` | Pause recording without closing encoder or file |
| `resume()` | Resume recording from paused state |
| `stop()` | Flush remaining frames, close file, and return output path |

### `AlmanacRecordMp3Status`

`idle` · `recording` · `paused`

### Parameter Validation

| Parameter | Valid values |
| --- | --- |
| `sampleRate` | 16000, 22050, 44100, 48000 |
| `numChannels` | 1, 2 |
| `bitRate` | 32, 48, 64, 96, 128, 160, 192, 256, 320 |

An `ArgumentError` is thrown for values outside the listed sets.

---

## Architecture

```text
Microphone (PCM 16-bit)
       │
       ▼
 [AudioRecord / AVAudioEngine]
       │  raw PCM frames
       ▼
 [LAME 3.100 — vendored C library]
       │  MP3 frames (CBR)
       ▼
 [FileOutputStream / FILE*]
       │
       ▼
    output.mp3
```

* **Android:** JNI bridge (`native-lib.cpp`) -> LAME compiled via CMake (NDK r28). Hardware capture runs at 44 100 Hz mono; LAME resamples to the requested output configuration.
* **iOS:** `AVAudioEngine` tap -> `AVAudioConverter` -> C wrapper (`AlmanacLame.c`) -> LAME compiled via CocoaPods. The tap format tracks hardware input; converter targets the requested rate and channels as interleaved int16 PCM.

---

## LAME Vendoring

LAME sources are vendored at:

* `android/src/main/cpp/lame/`
* `ios/Classes/lame/`

To re-vendor (e.g., for upstream LAME releases):

```bash
bash scripts/fetch_lame.sh
```

The script downloads LAME 3.100, verifies the SHA-256 checksum, copies the required sources, applies compatibility patches, and preserves the hand-written `config.h` files.

---

## Limitations

* **Background recording:** Not supported in 1.0.0. Recording stops when the application is backgrounded.
* **Swift Package Manager:** iOS integration via SPM is out of scope for 1.0.0. CocoaPods is the supported dependency manager.
* **Simulator (iOS):** The legacy `i386` simulator slice is excluded (`EXCLUDED_ARCHS[sdk=iphonesimulator*] = i386`). Run on a physical device or an `arm64`/`x86_64` simulator.

---

## License

### Plugin Code

The plugin source code is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for full text.

### LAME (Third-party)

This package includes **LAME 3.100**, copyright (c) 1999–2011 The LAME Project, licensed under the **GNU Lesser General Public License v2 or later (LGPL v2+)**. See [`third_party/lame/COPYING`](third_party/lame/COPYING) for the full text.

**Important for application developers:** LAME is statically compiled into your app by this plugin. The LGPL requires that your users be able to relink your app against a modified version of LAME. Please consult the LGPL text and legal guidance appropriate to your distribution model.

**Note on MP3 patents:** All relevant MP3 patents expired by April 2017. MP3 encoding and decoding are patent-free worldwide.

---

## Contributing

Pull requests are welcome. Please run `flutter analyze` and `flutter test` before submitting changes.
