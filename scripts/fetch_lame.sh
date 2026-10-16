#!/usr/bin/env bash
# =============================================================================
# scripts/fetch_lame.sh
#
# Downloads and vendors LAME 3.100 sources into the almanacinc_record_mp3
# plugin tree. This script is idempotent and safe to re-run.
#
# WHAT THIS SCRIPT DOES
# ─────────────────────
#  1. Downloads the official LAME 3.100 release tarball from SourceForge.
#  2. Verifies the SHA-256 checksum; aborts on mismatch.
#  3. Copies ONLY the required sources from the tarball:
#       libmp3lame/*.c  libmp3lame/*.h  include/lame.h
#     into:
#       android/src/main/cpp/lame/        (lame.h placed here directly)
#       ios/Classes/lame/                 (lame.h placed in include/ subdir)
#  4. EXCLUDES frontend/, mpglib/, vector/ (SSE — breaks ARM builds), and
#     all Makefiles.
#  5. Applies three idempotent compatibility patches via sed:
#       util.h    — replaces ieee754_float32_t with float in fast_log2 decl
#       set_get.h — replaces #include <lame.h> with #include "lame.h"
#       fft.c     — comments out #include "vector/lame_intrin.h"
#  6. NEVER overwrites the hand-written config.h files in either destination.
#  7. Copies LAME's COPYING license to third_party/lame/COPYING.
#
# USAGE
# ─────
#   bash scripts/fetch_lame.sh
#
# REQUIREMENTS
#   curl (preferred) or wget  ·  shasum (macOS) or sha256sum (Linux)  ·  tar
#
# NOTE
# ────
# Vendored LAME sources ARE committed to the repository and included in the
# published pub.dev package. App developers using this plugin do NOT need to
# run this script. It exists solely for reproducibility and future upgrades.
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
readonly LAME_VERSION="3.100"
readonly LAME_TARBALL="lame-${LAME_VERSION}.tar.gz"
readonly LAME_URL="https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/${LAME_TARBALL}/download"
readonly LAME_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly ANDROID_LAME="${REPO_ROOT}/android/src/main/cpp/lame"
readonly IOS_LAME="${REPO_ROOT}/ios/Classes/lame"
readonly IOS_INCLUDE="${IOS_LAME}/include"
readonly THIRD_PARTY="${REPO_ROOT}/third_party/lame"

# ── Temp workspace (cleaned up on exit) ───────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { printf '[fetch_lame] %s\n' "$*"; }
die() { printf '[fetch_lame] ERROR: %s\n' "$*" >&2; exit 1; }

# =============================================================================
# STEP 1 — Download
# =============================================================================
TARBALL="${TMP_DIR}/${LAME_TARBALL}"
log "Downloading LAME ${LAME_VERSION}..."
if command -v curl >/dev/null 2>&1; then
    curl -L --fail --silent --show-error -o "${TARBALL}" "${LAME_URL}"
elif command -v wget >/dev/null 2>&1; then
    wget --quiet -O "${TARBALL}" "${LAME_URL}"
else
    die "Neither curl nor wget found. Install one and retry."
fi
log "Download complete."

# =============================================================================
# STEP 2 — Verify SHA-256
# =============================================================================
log "Verifying SHA-256 checksum..."
if command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "${TARBALL}" | awk '{print $1}')"
else
    die "Neither shasum nor sha256sum found. Cannot verify integrity."
fi
if [ "${ACTUAL}" != "${LAME_SHA256}" ]; then
    die "SHA-256 mismatch.
  Expected : ${LAME_SHA256}
  Actual   : ${ACTUAL}
Refusing to continue with an unverified tarball."
fi
log "SHA-256 verified: ${ACTUAL}"

# =============================================================================
# STEP 3 — Extract
# =============================================================================
log "Extracting ${LAME_TARBALL}..."
tar -xzf "${TARBALL}" -C "${TMP_DIR}"
readonly LAME_SRC="${TMP_DIR}/lame-${LAME_VERSION}"

# =============================================================================
# STEP 4 — Copy sources
#
# copy_sources <dest_dir> <lame_h_dest_dir>
#   dest_dir      — receives libmp3lame/*.c and *.h (maxdepth 1, no vector/)
#   lame_h_dest   — receives include/lame.h
#
# config.h is NEVER copied; the hand-written version in the repository is
# always preserved.
# =============================================================================
copy_sources() {
    local DEST="$1"
    local LAME_H_DEST="$2"

    mkdir -p "${DEST}" "${LAME_H_DEST}"

    log "  Copying libmp3lame/ sources → ${DEST} ..."
    local count=0
    while IFS= read -r -d '' src_file; do
        local filename
        filename="$(basename "${src_file}")"

        # Preserve the hand-written config.h.
        if [ "${filename}" = "config.h" ]; then
            log "  Skipping config.h (hand-written file — preserved)"
            continue
        fi

        cp "${src_file}" "${DEST}/${filename}"
        count=$((count + 1))
    done < <(
        find "${LAME_SRC}/libmp3lame" \
            -maxdepth 1 \
            -type f \
            \( -name "*.c" -o -name "*.h" \) \
            -print0
    )
    log "  Copied ${count} file(s)."

    log "  Copying include/lame.h → ${LAME_H_DEST}/lame.h ..."
    cp "${LAME_SRC}/include/lame.h" "${LAME_H_DEST}/lame.h"
}

log "Vendoring LAME into Android..."
copy_sources "${ANDROID_LAME}" "${ANDROID_LAME}"

log "Vendoring LAME into iOS..."
copy_sources "${IOS_LAME}" "${IOS_INCLUDE}"

# =============================================================================
# STEP 5 — Apply compatibility patches
#
# Both patches are idempotent: if the search pattern is already absent (because
# the file was already patched on a previous run), sed performs no replacement
# and exits 0.
# =============================================================================
apply_patches() {
    local DIR="$1"

    # ── Patch A: util.h ───────────────────────────────────────────────────────
    # Problem : LAME declares fast_log2 using ieee754_float32_t, which is
    #           defined by <ieee754.h> (glibc). That header is absent from the
    #           Android NDK sysroot and the Apple SDK.
    # Fix     : Replace the type with plain `float` in the extern declaration.
    #           Our hand-written config.h already typedef-aliases
    #           ieee754_float32_t to float for any remaining internal uses.
    if [ -f "${DIR}/util.h" ]; then
        sed -i.bak \
            's/extern ieee754_float32_t fast_log2(ieee754_float32_t x);/extern float fast_log2(float x);/g' \
            "${DIR}/util.h"
        rm -f "${DIR}/util.h.bak"
        log "  Patched util.h  : ieee754_float32_t → float in fast_log2 declaration"
    else
        log "  util.h not found in ${DIR} — skipping Patch A"
    fi

    # ── Patch B: set_get.h ────────────────────────────────────────────────────
    # Problem : set_get.h uses #include <lame.h> (system include), which works
    #           in an installed LAME build but fails when the sources are
    #           vendored alongside the header at the same directory level.
    # Fix     : Switch to a relative include so the build system's configured
    #           HEADER_SEARCH_PATHS can resolve it.
    if [ -f "${DIR}/set_get.h" ]; then
        sed -i.bak \
            's/#include <lame\.h>/#include "lame.h"/g' \
            "${DIR}/set_get.h"
        rm -f "${DIR}/set_get.h.bak"
        log "  Patched set_get.h: #include <lame.h> → #include \"lame.h\""
    else
        log "  set_get.h not found in ${DIR} — skipping Patch B"
    fi

    # ── Patch C: fft.c ────────────────────────────────────────────────────────
    # Problem : fft.c includes "vector/lame_intrin.h", which is omitted from the
    #           vendored tree because SSE/vector sources break ARM mobile targets.
    # Fix     : Comment out the include statement.
    if [ -f "${DIR}/fft.c" ]; then
        sed -i.bak \
            's/#include "vector\/lame_intrin\.h"/\/\* #include "vector\/lame_intrin\.h" \*\//g' \
            "${DIR}/fft.c"
        rm -f "${DIR}/fft.c.bak"
        log "  Patched fft.c   : commented out #include \"vector/lame_intrin.h\""
    else
        log "  fft.c not found in ${DIR} — skipping Patch C"
    fi
}

log "Applying patches to Android sources..."
apply_patches "${ANDROID_LAME}"

log "Applying patches to iOS sources..."
apply_patches "${IOS_LAME}"

# =============================================================================
# STEP 6 — Copy LAME license
# =============================================================================
mkdir -p "${THIRD_PARTY}"
cp "${LAME_SRC}/COPYING" "${THIRD_PARTY}/COPYING"
log "Copied LAME COPYING → third_party/lame/COPYING"

# =============================================================================
# Done
# =============================================================================
log ""
log "✓ LAME ${LAME_VERSION} vendored successfully."
log "  Android : ${ANDROID_LAME}"
log "  iOS     : ${IOS_LAME}"
log "  License : ${THIRD_PARTY}/COPYING"
log ""
log "Next step — commit the vendored sources:"
log "  git add android/src/main/cpp/lame \\"
log "          ios/Classes/lame \\"
log "          third_party/lame"
log "  git commit -m 'chore: vendor LAME ${LAME_VERSION}'"
