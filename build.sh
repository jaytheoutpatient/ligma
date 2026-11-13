#!/usr/bin/env bash
#
# Ligma build helper. The script wraps the Zig build with the environment
# checks and desktop-integration steps that a fresh checkout needs.
#
# Examples:
#   ./build.sh                 # ReleaseSafe build + desktop assets
#   ./build.sh --test          # build and run the unit tests
#   ./build.sh --debug         # Debug build
#   ./build.sh --install       # install binary and desktop integration
#   ./build.sh --run           # build and launch
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

OPTIMIZE="ReleaseSafe"
RUN_TESTS=0
DO_INSTALL=0
DO_RUN=0
DO_CLEAN=0

usage() {
    cat <<'EOF'
Usage: ./build.sh [options]

Options:
  --debug       Build with Debug optimizations instead of ReleaseSafe.
  --release     Build with ReleaseSafe optimizations (default).
  --test        Run the unit tests with an offscreen Qt platform first.
  --install     Install the binary and assets system-wide (needs sudo).
  --run         Launch the built binary after building.
  --clean       Remove .zig-cache/ and zig-out/ before building.
  -h, --help    Show this help text.

Examples:
  ./build.sh --test
  ./build.sh --install
  ./build.sh --debug --run
EOF
}

while (($# > 0)); do
    case "$1" in
        --debug) OPTIMIZE="Debug" ;;
        --release) OPTIMIZE="ReleaseSafe" ;;
        --test) RUN_TESTS=1 ;;
        --install) DO_INSTALL=1 ;;
        --run) DO_RUN=1 ;;
        --clean) DO_CLEAN=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf 'error: unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

need_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'error: %s is required but was not found in PATH.\n' "$1" >&2
        exit 1
    fi
}

need_pkg() {
    if ! pkg-config --exists "$1"; then
        printf 'error: pkg-config could not find %s development files.\n' "$1" >&2
        exit 1
    fi
}

need_command zig
need_command g++
need_command pkg-config
need_pkg qtermwidget6
need_pkg Qt6Multimedia
need_pkg sqlite3

printf 'Ligma build\n'
printf '  Zig:      %s\n' "$(zig version)"
printf '  Optimize: %s\n' "$OPTIMIZE"
printf '  Root:     %s\n\n' "$ROOT"

if ((DO_CLEAN)); then
    printf 'Cleaning build outputs...\n'
    rm -rf .zig-cache zig-out
fi

printf 'Building...\n'
zig build -Doptimize="$OPTIMIZE"

if ((RUN_TESTS)); then
    printf '\nRunning tests...\n'
    QT_QPA_PLATFORM=offscreen zig build test -Doptimize="$OPTIMIZE"
fi

printf '\nBuild complete:\n'
printf '  %s\n' "$ROOT/zig-out/bin/ligma"
printf '  %s\n' "$ROOT/zig-out/share"

if ((DO_INSTALL)); then
    if ((EUID == 0)); then
        SUDO=""
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        "$SUDO" -v
    else
        printf 'error: --install needs root or sudo.\n' >&2
        exit 1
    fi

    printf '\nInstalling to /usr...\n'
    $SUDO install -Dm755 zig-out/bin/ligma /usr/bin/ligma
    $SUDO cp -a zig-out/share/. /usr/share/

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        $SUDO gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        $SUDO update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    fi
    printf 'Installed /usr/bin/ligma and desktop assets.\n'
fi

if ((DO_RUN)); then
    printf '\nLaunching Ligma...\n'
    exec "$ROOT/zig-out/bin/ligma"
fi
