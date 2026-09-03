#!/usr/bin/env bash
#
# Fetches the parts of the Havok 2010.2 SDK that mopper needs.
#
# The SDK is a 472 MB 7z holding 2.94 GB of demos, docs, tools and every library
# flavour. mopper needs two of those directories and nothing else, so this
# extracts only Source/ and one Lib/ flavour -- about 215 MB.
#
# The archive is a single solid LZMA block (5,531 of its 5,545 files), so a
# partial extract still decompresses the whole stream. This saves disk and cache
# space, not time. Budget a few minutes.
#
# The SDK is not redistributable, so nothing this downloads belongs in a commit,
# a release asset, or a package. Use it to build and let it go.
#
# Usage:
#   ./scripts/fetch-havok.sh /path/to/put/the/sdk
#
# Environment:
#   HAVOK_LIB_SUBDIR which Lib/ flavour to extract; must match CMake's
#                    HAVOK_LIB_SUBDIR (default win32_net_9-0/release_multithreaded)
#   HAVOK_URL        where to download from. Overridable because the default is a
#                    third-party re-upload that could disappear
#
set -euo pipefail

HAVOK_LIB_SUBDIR="${HAVOK_LIB_SUBDIR:-win32_net_9-0/release_multithreaded}"
HAVOK_URL="${HAVOK_URL:-https://archive.org/download/Havok2010HCTSDK/hk2010_2_0_r1.7z}"
HAVOK_SHA1="${HAVOK_SHA1:-164b856d38f05b7a7a35b03bfffd3da8d761da2c}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 /path/to/put/the/sdk"

DEST="$1"
SENTINEL="$DEST/Source/Common/Base/hkBase.h"

if [ -f "$SENTINEL" ]; then
    log "Havok SDK already present at $DEST, nothing to do"
    exit 0
fi

command -v 7z >/dev/null 2>&1 || die "7z is not installed (apt install p7zip-full)"

mkdir -p "$DEST"
ARCHIVE="$(mktemp -d)/hk2010_2_0_r1.7z"
trap 'rm -rf "$(dirname "$ARCHIVE")"' EXIT

log "downloading $HAVOK_URL (472 MB)"
curl --location --fail --retry 3 --retry-delay 5 --output "$ARCHIVE" "$HAVOK_URL"

log "verifying SHA1"
actual="$(sha1sum "$ARCHIVE" | cut -d' ' -f1)"

if [ "$actual" != "$HAVOK_SHA1" ]; then
    die "SHA1 mismatch on the Havok archive.
  expected $HAVOK_SHA1
  got      $actual
Refusing to build against an archive that is not the one this was pinned to."
fi

log "extracting Source/ and Lib/$HAVOK_LIB_SUBDIR/ into $DEST"
7z x -y -o"$DEST" "$ARCHIVE" 'Source/*' "Lib/$HAVOK_LIB_SUBDIR/*" >/dev/null

# The archive layout is the contract here, so check it rather than letting a
# change surface later as a confusing CMake error.
[ -f "$SENTINEL" ] || die "extracted, but there is no Source/Common/Base/hkBase.h under $DEST"
[ -f "$DEST/Lib/$HAVOK_LIB_SUBDIR/hkBase.lib" ] \
    || die "extracted, but there is no hkBase.lib under $DEST/Lib/$HAVOK_LIB_SUBDIR"

log "ready at $DEST ($(du -sh "$DEST" | cut -f1))"
