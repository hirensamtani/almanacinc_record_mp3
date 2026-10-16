# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.4] - 2026-03-03

- Fixed Android NDK Clang compilation by stripping unsupported `vector/lame_intrin.h` include from `fft.c`.
- Verified 16 KB page-size shared library compilation across Android NDK r28 targets.

## [1.0.3] - 2026-03-03

- Standardized Swift Package Manager path to `ios/almanacinc_record_mp3/Package.swift` per Flutter SPM conventions.

## [1.0.2] - 2026-03-03

- Added native Swift Package Manager (SPM) support for iOS via `ios/Package.swift`.

## [1.0.1] - 2026-03-03

- Updated package metadata, pubspec URLs, and issue tracker.
- Standardized root MIT license formatting for automated OSI verification.

## [1.0.0] - 2024-10-16

### Added
- Initial release of `almanacinc_record_mp3`.
- Real-time MP3 encoding on Android and iOS using vendored LAME 3.100.
- Zero-conversion architecture: raw 16-bit PCM flows directly to the LAME
  encoder and MP3 frames are written immediately to disk — no WAV intermediate.
- CBR encoding at configurable bit rate (32–320 kbps).
- Mono and stereo recording (1 or 2 channels).
- Configurable sample rates: 16 000 Hz, 22 050 Hz, 44 100 Hz, 48 000 Hz.
- Pause / resume support without closing the encoder or file.
- `AVAudioSession` interruption handling on iOS (auto-pause on interruption).
- `AVAudioEngine` configuration-change recovery on iOS (tap rebuild on
  hardware route change).
- `RECORD_AUDIO` runtime permission management on Android.
- `AVAudioSession.requestRecordPermission` on iOS.
- 16 KB page-size–aligned shared library on Android (Android 15/16 compatible).
- Privacy manifest (`PrivacyInfo.xcprivacy`) for iOS App Store compliance.
- Dart API: `AlmanacRecordMp3.instance`, `start`, `pause`, `resume`, `stop`,
  `hasPermission`, `onStatusChanged`, `onError` streams, and `status` getter.
- Full `///` documentation on all public Dart symbols.
- Example app demonstrating the full recording lifecycle.
- GitHub Actions CI: `flutter analyze` + unit tests on macOS and Ubuntu runners.
