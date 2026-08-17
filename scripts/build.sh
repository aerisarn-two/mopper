#!/usr/bin/env bash
#
# Builds mopper.exe on Linux using the MSVC toolchain that install-deps.sh set up.
#
# Usage:
#   ./scripts/build.sh /path/to/havok_2010_2_0 [build-dir]
#
# Environment:
#   MSVC_DIR         where the MSVC toolchain lives (default ~/.local/share/msvc)
#   HAVOK_LIB_SUBDIR which Lib/ subdirectory to link
#                    (default win32_net_9-0/release_multithreaded)
#   BUILD_TYPE       CMake build type (default Release)
#
set -euo pipefail

MSVC_DIR="${MSVC_DIR:-$HOME/.local/share/msvc}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
HAVOK_LIB_SUBDIR="${HAVOK_LIB_SUBDIR:-win32_net_9-0/release_multithreaded}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

if [ $# -lt 1 ]; then
    die "usage: $0 /path/to/havok_sdk [build-dir]"
fi

HAVOK_SDK_DIR="$(cd "$1" && pwd)" || die "cannot resolve Havok SDK path: $1"
BUILD_DIR="${2:-build}"

[ -d "$HAVOK_SDK_DIR/Source" ] || die "no Source/ under $HAVOK_SDK_DIR"
[ -d "$HAVOK_SDK_DIR/Lib" ] || die "no Lib/ under $HAVOK_SDK_DIR"

if [ ! -x "$MSVC_DIR/bin/x86/cl" ]; then
    die "no x86 compiler at $MSVC_DIR/bin/x86/cl. Run ./scripts/install-deps.sh first."
fi

# The Havok libraries are 32-bit, so the x86 cross-compiler is the one to use.
export PATH="$MSVC_DIR/bin/x86:$PATH"

log "Havok SDK:  $HAVOK_SDK_DIR"
log "Havok libs: Lib/$HAVOK_LIB_SUBDIR"
log "toolchain:  $MSVC_DIR/bin/x86"

GENERATOR="Ninja"
command -v ninja >/dev/null 2>&1 || GENERATOR="Unix Makefiles"

CC=cl CXX=cl cmake -B "$BUILD_DIR" -G "$GENERATOR" \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DHAVOK_SDK_DIR="$HAVOK_SDK_DIR" \
    -DHAVOK_LIB_SUBDIR="$HAVOK_LIB_SUBDIR"

cmake --build "$BUILD_DIR" --config "$BUILD_TYPE"

MOPPER="$(find "$BUILD_DIR" -name 'mopper.exe' -print -quit)"

if [ -z "$MOPPER" ]; then
    die "build finished but no mopper.exe was produced"
fi

log "built $MOPPER"

# A quick smoke test, but only when 32-bit Wine can actually run it. Building
# needs just wine64; running a 32-bit binary needs WoW64 or i386 multiarch.
if wine "$MOPPER" --help >/dev/null 2>&1; then
    log "smoke test passed: mopper responds to --help"
else
    cat >&2 <<EOF

note: could not run $MOPPER under Wine here.
      Building only needs 64-bit Wine, but *running* a 32-bit Windows binary
      needs 32-bit support. On Debian/Ubuntu:

          sudo dpkg --add-architecture i386
          sudo apt-get update
          sudo apt-get install wine32

      The binary itself is fine; this is only about running it locally.
EOF
fi
