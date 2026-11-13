#!/usr/bin/env bash
#
# Ligma build helper. The script wraps the Zig build with the environment
# checks and desktop-integration steps that a fresh checkout needs.
#
# Examples:
#   ./build.sh                 # install missing dependencies and build
#                              # (downloads a local Zig compiler if needed)
#   ./build.sh --test          # build and run the unit tests
#   ./build.sh --debug         # Debug build
#   ./build.sh --install       # install binary and desktop integration
#   ./build.sh --install-deps  # force a dependency check/install
#   ./build.sh --run           # build and launch
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

OPTIMIZE="ReleaseSafe"
RUN_TESTS=0
DO_INSTALL=0
DO_INSTALL_DEPS=0
DO_RUN=0
DO_CLEAN=0
SUDO=()

usage() {
    cat <<'EOF'
Usage: ./build.sh [options]

Options:
  --debug       Build with Debug optimizations instead of ReleaseSafe.
  --release     Build with ReleaseSafe optimizations (default).
  --test        Run the unit tests with an offscreen Qt platform first.
  --install     Install the binary and assets system-wide (needs sudo).
  --install-deps
                Force the development-package installer to run. This is
                automatic when a dependency is missing. If Zig 0.17+ is not
                available, an official compiler is downloaded to .tools/.
  --run         Launch the built binary after building.
  --clean       Remove .zig-cache/ and zig-out/ before building.
  -h, --help    Show this help text.

Examples:
  ./build.sh
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
        --install-deps) DO_INSTALL_DEPS=1 ;;
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
        printf 'Install the missing development package or see README.md.\n' >&2
        exit 1
    fi
}

zig_version_ok() {
    command -v zig >/dev/null 2>&1 || return 1
    local version
    version="$(zig version 2>/dev/null || true)"
    [[ -n "$version" ]] || return 1
    [[ "$(printf '%s\n' 0.17.0 "$version" | sort -V | head -n1)" == "0.17.0" ]]
}

system_deps_ready() {
    command -v g++ >/dev/null 2>&1 || return 1
    command -v pkg-config >/dev/null 2>&1 || return 1
    pkg-config --exists qtermwidget6 Qt6Multimedia sqlite3
}

ZIG_BOOTSTRAP_VERSION="0.17.0"

activate_local_zig() {
    local dir
    for dir in "$ROOT"/.tools/zig-*-linux-*; do
        [[ -x "$dir/zig" ]] || continue
        export PATH="$dir:$PATH"
        hash -r
        if zig_version_ok; then
            return 0
        fi
    done
    return 1
}

bootstrap_zig() {
    if zig_version_ok; then
        return 0
    fi
    activate_local_zig && return 0

    local machine
    machine="$(uname -m)"
    local zig_arch
    local expected_sha
    case "$machine" in
        x86_64|amd64)
            zig_arch="x86_64"
            expected_sha="1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026"
            ;;
        aarch64|arm64)
            zig_arch="aarch64"
            expected_sha="9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8"
            ;;
        armv7l|armv6l|arm)
            zig_arch="arm"
            expected_sha="53f0045cdef7ba06da70a12b2ef654e4c5283b0139bc441aa7d84f364b46de43"
            ;;
        riscv64)
            zig_arch="riscv64"
            expected_sha="18ff032ac6cecf746a84259f6463264f13160ff88bc3b80722ce06f9479b82ed"
            ;;
        ppc64le|powerpc64le)
            zig_arch="powerpc64le"
            expected_sha="731e2887e66fff41fdc34f7fd9d8afa814d86d7426f5827805f8854b2977684b"
            ;;
        i386|i686|x86)
            zig_arch="x86"
            expected_sha="55e39e175cd5b3098afc29ec47b2590134f5b874175369fb9ae7b8e836d7531a"
            ;;
        loongarch64)
            zig_arch="loongarch64"
            expected_sha="5a6000b866201c3b3820b563fcfd29641185393e7d35039e50235db418d8367c"
            ;;
        s390x)
            zig_arch="s390x"
            expected_sha="13905f11989b65566c544d191d4bc5bd5d6f858e303208cf1d2f090e5d91b512"
            ;;
        *)
            printf 'error: no official Zig build is available for %s.\n' "$machine" >&2
            printf 'Download Zig 0.17.0 or newer manually from https://ziglang.org/download/\n' >&2
            exit 1
            ;;
    esac

    need_command tar
    need_command sha256sum
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        printf 'error: curl or wget is required to download Zig.\n' >&2
        exit 1
    fi

    local zig_name="zig-${zig_arch}-linux-${ZIG_BOOTSTRAP_VERSION}"
    local tools_dir="$ROOT/.tools"
    local archive="$tools_dir/${zig_name}.tar.xz"
    local destination="$tools_dir/$zig_name"
    local url="https://ziglang.org/download/${ZIG_BOOTSTRAP_VERSION}/${zig_name}.tar.xz"

    mkdir -p "$tools_dir"
    if [[ ! -f "$archive" ]]; then
        printf 'Zig %s was not found; downloading the official compiler...\n' "$ZIG_BOOTSTRAP_VERSION"
        printf '  %s\n' "$url"
        if command -v curl >/dev/null 2>&1; then
            if ! curl -fL --retry 3 -o "$archive" "$url"; then
                rm -f "$archive"
                printf 'error: could not download Zig.\n' >&2
                exit 1
            fi
        else
            if ! wget -O "$archive" "$url"; then
                rm -f "$archive"
                printf 'error: could not download Zig.\n' >&2
                exit 1
            fi
        fi
    fi

    local actual_sha
    actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        rm -f "$archive"
        printf 'error: Zig archive checksum mismatch.\n' >&2
        exit 1
    fi

    printf 'Extracting Zig %s into %s...\n' "$ZIG_BOOTSTRAP_VERSION" "$tools_dir"
    if ! tar -xJf "$archive" -C "$tools_dir"; then
        printf 'error: could not extract the Zig archive.\n' >&2
        exit 1
    fi
    rm -f "$archive"

    if [[ ! -x "$destination/zig" ]]; then
        printf 'error: Zig executable not found after extraction.\n' >&2
        exit 1
    fi

    export PATH="$destination:$PATH"
    hash -r
    if ! zig_version_ok; then
        printf 'error: the downloaded Zig compiler failed its version check.\n' >&2
        exit 1
    fi
    printf 'Using local Zig: %s (%s)\n' "$(zig version)" "$destination"
}

ensure_zig() {
    if zig_version_ok; then
        return 0
    fi
    activate_local_zig || true
    if zig_version_ok; then
        return 0
    fi
    bootstrap_zig
}

setup_sudo() {
    if ((EUID == 0)); then
        SUDO=()
    elif command -v sudo >/dev/null 2>&1; then
        SUDO=(sudo)
        "${SUDO[@]}" -v
    else
        printf 'error: this action needs root or sudo.\n' >&2
        exit 1
    fi
}

confirm_install() {
    if [[ "${LIGMA_ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    local answer
    read -r -p "Install these packages with $1? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) printf 'Cancelled.\n'; exit 1 ;;
    esac
}

install_deps() {
    setup_sudo

    if command -v pacman >/dev/null 2>&1; then
        local packages=(base-devel pkgconf qt6-base qt6-multimedia
            qt6-multimedia-ffmpeg sqlite qtermwidget zig)
        printf 'Detected pacman. Installing: %s\n' "${packages[*]}"
        confirm_install pacman
        "${SUDO[@]}" pacman -S --needed "${packages[@]}"
    elif command -v apt-get >/dev/null 2>&1; then
        local packages=(build-essential pkg-config qt6-base-dev
            qt6-multimedia-dev libsqlite3-dev)
        "${SUDO[@]}" apt-get update
        local candidate=""
        local qterm_package=""
        for candidate in libqtermwidget6-2-dev libqtermwidget6-dev \
            libqtermwidget6-1-dev; do
            if apt-cache show "$candidate" >/dev/null 2>&1; then
                qterm_package="$candidate"
                break
            fi
        done
        if [[ -z "$qterm_package" ]]; then
            printf 'error: no Qt 6 QTermWidget development package was found.\n' >&2
            printf 'Install qtermwidget6 for Qt 6 manually, then rerun the build.\n' >&2
            exit 1
        fi
        packages+=("$qterm_package")
        printf 'Detected apt. Installing: %s\n' "${packages[*]}"
        confirm_install apt
        "${SUDO[@]}" apt-get install -y "${packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        local packages=(gcc-c++ pkgconf-pkg-config qt6-qtbase-devel
            qt6-qtmultimedia-devel sqlite-devel qtermwidget-devel)
        printf 'Detected dnf. Installing: %s\n' "${packages[*]}"
        confirm_install dnf
        "${SUDO[@]}" dnf install -y "${packages[@]}"
    else
        printf 'error: unsupported package manager.\n' >&2
        printf 'Install the packages listed in README.md manually.\n' >&2
        exit 1
    fi

    hash -r
}

activate_local_zig || true

if ((DO_INSTALL_DEPS)) || ! system_deps_ready; then
    if ! system_deps_ready; then
        printf 'Missing build dependencies; starting the package installer.\n'
    fi
    install_deps
fi

ensure_zig

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
    setup_sudo
    printf '\nInstalling to /usr...\n'
    "${SUDO[@]}" install -Dm755 zig-out/bin/ligma /usr/bin/ligma
    "${SUDO[@]}" cp -a zig-out/share/. /usr/share/

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        "${SUDO[@]}" gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        "${SUDO[@]}" update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    fi
    printf 'Installed /usr/bin/ligma and desktop assets.\n'
fi

if ((DO_RUN)); then
    printf '\nLaunching Ligma...\n'
    exec "$ROOT/zig-out/bin/ligma"
fi
