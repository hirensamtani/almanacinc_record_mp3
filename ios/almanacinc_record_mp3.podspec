Pod::Spec.new do |s|
  s.name             = 'almanacinc_record_mp3'
  s.version          = '1.0.0'
  s.summary          = 'Flutter plugin for real-time MP3 recording using vendored LAME 3.100.'
  s.description      = <<~DESC
    Captures microphone audio as raw 16-bit PCM via AVAudioEngine and encodes
    it directly to MP3 frames using the vendored LAME 3.100 C library — no
    intermediate WAV file and no post-conversion pass. CBR encoding only.
  DESC

  s.homepage         = 'https://github.com/almanacinc/almanacinc_record_mp3'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Almanac Inc.' => 'opensource@almanacinc.com' }
  s.source           = {
    :git => 'https://github.com/almanacinc/almanacinc_record_mp3.git',
    :tag => s.version.to_s
  }

  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'

  # ── Sources ──────────────────────────────────────────────────────────────
  # Includes: Swift plugin class, C wrapper (AlmanacLame.c), C wrapper header,
  #           umbrella header, and all vendored LAME *.c / *.h sources.
  # Excludes: nothing extra — LAME vector/ SSE sources are never copied by
  #           fetch_lame.sh, so they are never present in the pod tree.
  s.source_files = 'Classes/**/*.{swift,c,h}'

  # Headers the Swift module (and umbrella) expose to consumers.
  s.public_header_files = [
    'Classes/AlmanacLame.h',
    'Classes/almanacinc_record_mp3-umbrella.h'
  ]

  # LAME internal headers — compiled but not re-exported.
  s.private_header_files = 'Classes/lame/**/*.h'

  # ── Privacy manifest (iOS 17+ App Store requirement) ─────────────────────
  s.resource_bundles = {
    'almanacinc_record_mp3_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  # ── Dependency ────────────────────────────────────────────────────────────
  s.dependency 'Flutter'

  # ── Build settings ────────────────────────────────────────────────────────
  s.pod_target_xcconfig = {
    # Required for the generated Swift module to be importable.
    'DEFINES_MODULE'                          => 'YES',

    # Allow #include "lame.h" and #include "config.h" to resolve from
    # the vendored lame/ tree.
    'HEADER_SEARCH_PATHS'                     =>
      '"$(PODS_TARGET_SRCROOT)/Classes/lame/include" ' \
      '"$(PODS_TARGET_SRCROOT)/Classes/lame"',

    # Injects HAVE_CONFIG_H into every compiled C/ObjC/C++ translation unit
    # so the vendored LAME sources pick up our hand-written config.h.
    'GCC_PREPROCESSOR_DEFINITIONS'           => '$(inherited) HAVE_CONFIG_H=1',

    # Suppress all warnings from vendored LAME C sources.
    'GCC_WARN_INHIBIT_ALL_WARNINGS'           => 'YES',

    # Drop the legacy 32-bit i386 simulator slice (LAME + Swift don't build
    # for i386; Xcode 12+ simulators run on arm64 / x86_64 anyway).
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]'    => 'i386'
  }
end
