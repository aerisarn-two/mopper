#!/usr/bin/env bash
#
# Installs everything needed to build mopper.exe on Linux.
#
# mopper links the Havok SDK, which ships only as MSVC-compiled 32-bit static
# libraries. MinGW cannot link those -- MSVC and MinGW use different C++ ABIs and
# name mangling, so symbol resolution fails and no flag fixes it. The way round it
# is to run a real MSVC toolchain under Wine, which is what msvc-wine sets up.
#
# Only 64-bit Wine is needed to *build*: the compiler is an x64 host binary that
# cross-targets x86. Running the resulting 32-bit mopper.exe is a separate matter,
# see README-linux.md.
#
set -euo pipefail

MSVC_DIR="${MSVC_DIR:-$HOME/.local/share/msvc}"
MSVC_WINE_DIR="${MSVC_WINE_DIR:-$HOME/.local/share/msvc-wine}"
SKIP_PACKAGES="${SKIP_PACKAGES:-0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

# --- system packages ---------------------------------------------------------

install_packages() {
    if [ "$SKIP_PACKAGES" = "1" ]; then
        log "SKIP_PACKAGES=1, not touching system packages"
        return
    fi

    # msvc-wine needs msitools >= 0.98 and libgcab >= 1.2 to unpack the MSVC
    # installer payloads; those are in Ubuntu 19.04 and later.
    local packages=(wine64 python3 msitools ca-certificates winbind cmake ninja-build git curl)

    if command -v apt-get >/dev/null 2>&1; then
        log "installing packages with apt-get: ${packages[*]}"
        sudo apt-get update
        sudo apt-get install -y "${packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        log "installing packages with dnf"
        sudo dnf install -y wine python3 msitools ca-certificates samba-winbind cmake ninja-build git curl
    elif command -v pacman >/dev/null 2>&1; then
        log "installing packages with pacman"
        sudo pacman -S --needed --noconfirm wine python msitools ca-certificates samba cmake ninja git curl
    else
        warn "unknown package manager; install these yourself and re-run with SKIP_PACKAGES=1:"
        warn "  ${packages[*]}"
        die "cannot install system packages automatically"
    fi
}

# --- msvc-wine ---------------------------------------------------------------

install_msvc() {
    if [ -d "$MSVC_WINE_DIR/.git" ]; then
        log "updating msvc-wine in $MSVC_WINE_DIR"
        git -C "$MSVC_WINE_DIR" pull --ff-only
    else
        log "cloning msvc-wine into $MSVC_WINE_DIR"
        mkdir -p "$(dirname "$MSVC_WINE_DIR")"
        git clone https://github.com/mstorsjo/msvc-wine "$MSVC_WINE_DIR"
    fi

    if [ -x "$MSVC_DIR/bin/x86/cl" ]; then
        log "MSVC already installed at $MSVC_DIR, skipping download"
        return
    fi

    log "downloading the MSVC toolchain into $MSVC_DIR (this is a few GB)"
    mkdir -p "$MSVC_DIR"

    # Downloads the compiler and Windows SDK straight from Microsoft's package
    # feed. Accepting their licence is on you; vsdownload.py prints it.
    "$MSVC_WINE_DIR/vsdownload.py" --dest "$MSVC_DIR"

    log "setting up wrapper scripts"
    "$MSVC_WINE_DIR/install.sh" "$MSVC_DIR"
}

# --- wine prefix -------------------------------------------------------------

prepare_wine() {
    log "initialising the Wine prefix"

    # Keeps the first real build from racing wineboot.
    wineserver -k 2>/dev/null || true
    wine64 wineboot --init 2>/dev/null || warn "wineboot reported a problem; continuing"
    wineserver -w 2>/dev/null || true
}

# --- main --------------------------------------------------------------------

main() {
    install_packages
    install_msvc
    prepare_wine

    if [ ! -x "$MSVC_DIR/bin/x86/cl" ]; then
        die "expected an x86 compiler at $MSVC_DIR/bin/x86/cl but it is not there"
    fi

    cat <<EOF

$(log "done")

The x86 toolchain is at:
    $MSVC_DIR/bin/x86

Build mopper with:
    ./scripts/build.sh /path/to/havok_2010_2_0

or, by hand:
    export PATH="$MSVC_DIR/bin/x86:\$PATH"
    CC=cl CXX=cl cmake -B build -G Ninja \\
        -DCMAKE_SYSTEM_NAME=Windows \\
        -DCMAKE_BUILD_TYPE=Release \\
        -DHAVOK_SDK_DIR=/path/to/havok_2010_2_0
    cmake --build build

EOF
}

main "$@"
