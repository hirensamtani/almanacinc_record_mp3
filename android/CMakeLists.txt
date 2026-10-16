cmake_minimum_required(VERSION 3.22.1)

project(almanac_record_mp3 VERSION 1.0.0 LANGUAGES C CXX)

# ─────────────────────────────────────────────────────────────────────────────
# Collect LAME C sources (vendored under src/main/cpp/lame/).
# Exclude vector/ (SSE) and any test / frontend / mpglib files.
# ─────────────────────────────────────────────────────────────────────────────
file(GLOB LAME_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/lame/*.c"
)

# ─────────────────────────────────────────────────────────────────────────────
# Shared library: almanac_record_mp3
# Built from the JNI bridge + all vendored LAME sources.
# ─────────────────────────────────────────────────────────────────────────────
add_library(
    almanac_record_mp3
    SHARED
    src/main/cpp/native-lib.cpp
    ${LAME_SOURCES}
)

# ─────────────────────────────────────────────────────────────────────────────
# Include directories
# ─────────────────────────────────────────────────────────────────────────────
target_include_directories(almanac_record_mp3 PRIVATE
    # Hand-written config.h lives here; also exposes all LAME headers.
    ${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/lame
    # Standard Android NDK log header.
    ${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/${ANDROID_HOST_TAG}/sysroot/usr/include
)

# ─────────────────────────────────────────────────────────────────────────────
# Compiler definitions
# All sources need HAVE_CONFIG_H so LAME picks up our hand-written config.h.
# ─────────────────────────────────────────────────────────────────────────────
target_compile_definitions(almanac_record_mp3 PRIVATE
    HAVE_CONFIG_H
)

# ─────────────────────────────────────────────────────────────────────────────
# Per-source compile flags:
#   - LAME sources: suppress all warnings (-w) to avoid noise from vendored code.
#   - JNI bridge: standard C++17 with full warnings enabled.
# ─────────────────────────────────────────────────────────────────────────────
foreach(LAME_SRC IN LISTS LAME_SOURCES)
    set_source_files_properties(${LAME_SRC} PROPERTIES
        COMPILE_FLAGS "-w"
    )
endforeach()

set_source_files_properties(
    src/main/cpp/native-lib.cpp PROPERTIES
    COMPILE_FLAGS "-std=c++17 -Wall -Wextra"
)

# ─────────────────────────────────────────────────────────────────────────────
# 16 KB page-size alignment (required for Android 15/16 with 16 KB kernels).
# AGP ≥ 8.5.1 must be used to preserve this alignment during APK packaging.
# Verify post-build with:
#   llvm-objdump -p libalmanac_record_mp3.so | grep LOAD  → must show 2**14
#   zipalign -c -P 16 -v 4 app.apk
# ─────────────────────────────────────────────────────────────────────────────
target_link_options(almanac_record_mp3 PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384"
)

# ─────────────────────────────────────────────────────────────────────────────
# Link against the Android log library for __android_log_print.
# ─────────────────────────────────────────────────────────────────────────────
find_library(LOG_LIB log)
target_link_libraries(almanac_record_mp3 PRIVATE ${LOG_LIB})
