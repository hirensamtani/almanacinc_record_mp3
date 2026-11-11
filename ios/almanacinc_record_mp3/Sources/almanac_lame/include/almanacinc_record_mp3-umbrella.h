/*
 * almanacinc_record_mp3-umbrella.h
 * Copyright (c) 2024 Almanac Inc. — MIT License
 *
 * Module umbrella header for the almanacinc_record_mp3 CocoaPod.
 *
 * CocoaPods generates a Swift module clang module map that imports this
 * umbrella header.  By importing AlmanacLame.h here, Swift code in
 * SwiftAlmanacRecordMp3Plugin.swift can call AlmanacLame* functions
 * without a bridging header and without ever seeing lame.h internals.
 *
 * Usage in Swift:
 *   // No import needed inside the same pod target — the module map
 *   // already makes AlmanacLameHandle, AlmanacLameInit, etc. available.
 *
 * This header must NOT import lame.h directly or transitively — all LAME
 * symbols stay hidden behind the AlmanacLame abstraction layer.
 */

#ifndef ALMANACINC_RECORD_MP3_UMBRELLA_H
#define ALMANACINC_RECORD_MP3_UMBRELLA_H

#import "AlmanacLame.h"

#endif /* ALMANACINC_RECORD_MP3_UMBRELLA_H */
