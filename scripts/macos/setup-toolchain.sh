#!/usr/bin/env bash
# Install the RustDesk macOS build toolchain natively (no Docker).
#
# This is the macOS counterpart of scripts/windows/setup-toolchain.ps1: it
# installs what docker/*-builder.Dockerfile install for the other platforms,
# but onto a real Mac (or a macOS VM), because Apple's toolchain cannot run in
# a container.
#
# Installs / checks: Xcode command line tools, Homebrew packages (imagemagick,
# potrace, cmake, ninja, pkg-config, llvm, create-dmg, wget, nasm 2.16), Rust
# (rustup + the host target), Flutter, vcpkg and flutter_rust_bridge_codegen.
#
# Everything is skipped when already present — in particular an existing
# Flutter/Rust install on PATH is reused as-is, nothing is overwritten.
#
# Usage:
#   scripts/macos/setup-toolchain.sh [--install-root ~/rdgen-tools]
#
# Options:
#   --install-root DIR   where vcpkg / a managed Flutter go (default ~/rdgen-tools)
#   --flutter-version V  Flutter to install if none is on PATH (default 3.24.5)
#   --rust-version V     Rust toolchain to install if none is present (default 1.81)
#   --vcpkg-commit SHA   vcpkg commit to pin (default matches the workflows)
#   --force-flutter      install the pinned Flutter even if one is on PATH
#   -h, --help           this help
set -euo pipefail

INSTALL_ROOT="${RDGEN_INSTALL_ROOT:-$HOME/rdgen-tools}"
FLUTTER_VERSION="3.24.5"
RUST_VERSION="1.81"
VCPKG_COMMIT="120deac3062162151622ca4860575a33844ba10b"
NASM_VERSION="2.16.03"
FRB_VERSION="1.80.1"
FORCE_FLUTTER=0

usage() { sed -n '2,27p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)          usage 0 ;;
        --install-root)     INSTALL_ROOT="$2"; shift 2 ;;
        --flutter-version)  FLUTTER_VERSION="$2"; shift 2 ;;
        --rust-version)     RUST_VERSION="$2"; shift 2 ;;
        --vcpkg-commit)     VCPKG_COMMIT="$2"; shift 2 ;;
        --force-flutter)    FORCE_FLUTTER=1; shift ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

log()  { printf '\033[1;36m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
mkdir -p "$INSTALL_ROOT"
DOWNLOADS="$INSTALL_ROOT/downloads"
mkdir -p "$DOWNLOADS"

# --- Xcode command line tools ------------------------------------------------
if xcode-select -p >/dev/null 2>&1; then
    log "Xcode command line tools already present"
else
    log "installing Xcode command line tools (a GUI dialog may appear)"
    xcode-select --install || true
    die "re-run this script once the command line tools finish installing"
fi

# --- Homebrew ----------------------------------------------------------------
if ! have brew; then
    die "Homebrew is required. Install it from https://brew.sh and re-run."
fi

BREW_PKGS="imagemagick potrace cmake ninja pkg-config llvm create-dmg wget"
for pkg in $BREW_PKGS; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        log "$pkg already installed"
    else
        log "installing $pkg"
        brew install "$pkg"
    fi
done

# --- NASM 2.16 ---------------------------------------------------------------
# Do NOT use `brew install nasm`: it ships NASM 3.x, whose CLI is incompatible
# with the x86 assembly in aom/ffmpeg. Same reasoning as generator-macos.yml.
NASM_BIN="$INSTALL_ROOT/bin/nasm"
mkdir -p "$INSTALL_ROOT/bin"
if [ -x "$NASM_BIN" ]; then
    log "nasm $($NASM_BIN -v 2>/dev/null | head -n1) already present"
elif nasm -v 2>/dev/null | grep -q " 2\."; then
    log "system nasm 2.x already present"
else
    log "installing NASM $NASM_VERSION"
    ( cd "$DOWNLOADS"
      curl -fsSL -O "https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/macosx/nasm-${NASM_VERSION}-macosx.zip"
      unzip -oq "nasm-${NASM_VERSION}-macosx.zip"
      cp "nasm-${NASM_VERSION}/nasm" "$NASM_BIN" )
    chmod +x "$NASM_BIN"
fi

# --- Rust --------------------------------------------------------------------
export PATH="$HOME/.cargo/bin:$PATH"
if have cargo; then
    log "Rust already present ($(rustc -V))"
else
    log "installing Rust $RUST_VERSION via rustup"
    curl -fsSL https://sh.rustup.rs | sh -s -- -y \
        --default-toolchain "$RUST_VERSION" --profile minimal --component rustfmt
    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
fi
HOST_TARGET="x86_64-apple-darwin"
[ "$(uname -m)" = "arm64" ] && HOST_TARGET="aarch64-apple-darwin"
rustup target add "$HOST_TARGET" >/dev/null 2>&1 || true

# --- Flutter -----------------------------------------------------------------
MANAGED_FLUTTER="$INSTALL_ROOT/flutter"
FLUTTER_HOME=""
if have flutter && [ "$FORCE_FLUTTER" -eq 0 ]; then
    FLUTTER_HOME="$(cd "$(dirname "$(dirname "$(command -v flutter)")")" && pwd)"
    log "reusing the Flutter already on PATH: $FLUTTER_HOME ($(flutter --version 2>/dev/null | head -n1))"
    if ! flutter --version 2>/dev/null | head -n1 | grep -q "$FLUTTER_VERSION"; then
        warn "this is not Flutter $FLUTTER_VERSION, which the workflows pin."
        warn "builds usually still work; pass --force-flutter to install the pinned version under $MANAGED_FLUTTER."
    fi
elif [ -x "$MANAGED_FLUTTER/bin/flutter" ]; then
    FLUTTER_HOME="$MANAGED_FLUTTER"
    log "reusing managed Flutter at $FLUTTER_HOME"
else
    log "installing Flutter $FLUTTER_VERSION into $MANAGED_FLUTTER"
    arch_dir="x64"
    [ "$(uname -m)" = "arm64" ] && arch_dir="arm64"
    url="https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_${arch_dir}_${FLUTTER_VERSION}-stable.zip"
    ( cd "$DOWNLOADS"
      curl -fsSL -o flutter.zip "$url" || \
        curl -fsSL -o flutter.zip "https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_${FLUTTER_VERSION}-stable.zip"
      unzip -oq flutter.zip -d "$INSTALL_ROOT" )
    FLUTTER_HOME="$MANAGED_FLUTTER"
fi
export PATH="$FLUTTER_HOME/bin:$PATH"
git config --global --add safe.directory '*' >/dev/null 2>&1 || true
flutter config --no-analytics >/dev/null 2>&1 || true
flutter precache --macos >/dev/null 2>&1 || true

# Flutter patches the workflow applies. Both are best-effort.
PATCH="$REPO_ROOT/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
if [ -f "$PATCH" ] && flutter --version 2>/dev/null | head -n1 | grep -q "3.24.5"; then
    ( cd "$FLUTTER_HOME" && git apply "$PATCH" 2>/dev/null ) \
        && log "applied the dropdown_menu patch" \
        || log "dropdown_menu patch already applied or not applicable"
fi
# https://github.com/flutter/flutter/issues/133533
BINDING="$FLUTTER_HOME/packages/flutter/lib/src/scheduler/binding.dart"
if [ -f "$BINDING" ] && grep -q '^\s*_setFramesEnabledState(false);' "$BINDING"; then
    log "applying the _setFramesEnabledState workaround"
    sed -i '' -e 's|_setFramesEnabledState(false);|//_setFramesEnabledState(false);|g' "$BINDING"
fi

# --- CocoaPods ---------------------------------------------------------------
if have pod; then
    log "CocoaPods already present"
else
    log "installing CocoaPods"
    brew install cocoapods
fi

# --- vcpkg -------------------------------------------------------------------
VCPKG_ROOT="$INSTALL_ROOT/vcpkg"
if [ -x "$VCPKG_ROOT/vcpkg" ]; then
    log "vcpkg already present"
else
    log "bootstrapping vcpkg"
    [ -d "$VCPKG_ROOT/.git" ] || git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
    ( cd "$VCPKG_ROOT" && git fetch --depth 1 origin "$VCPKG_COMMIT" 2>/dev/null || true
      git checkout "$VCPKG_COMMIT"
      ./bootstrap-vcpkg.sh -disableMetrics )
fi

# --- flutter_rust_bridge codegen --------------------------------------------
if have flutter_rust_bridge_codegen; then
    log "flutter_rust_bridge_codegen already present"
else
    log "installing flutter_rust_bridge_codegen (compiles from source, slow)"
    cargo install cargo-expand --version 1.0.95 --locked
    cargo install flutter_rust_bridge_codegen --version "$FRB_VERSION" --features uuid --locked
fi

# --- rcodesign (optional, only needed for .p12 signing) ----------------------
if have rcodesign; then
    log "rcodesign already present"
else
    log "rcodesign not installed — builds will be ad-hoc signed."
    log "  install it with: brew install rcodesign   (only needed for a real Developer ID)"
fi

# --- env file the build wrapper sources --------------------------------------
LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null || echo /usr/local/opt/llvm)"
cat > "$INSTALL_ROOT/env.sh" <<EOF
# Generated by scripts/macos/setup-toolchain.sh — source this before building.
export VCPKG_ROOT="$VCPKG_ROOT"
export LIBCLANG_PATH="$LLVM_PREFIX/lib"
export PATH="\$HOME/.cargo/bin:$FLUTTER_HOME/bin:$INSTALL_ROOT/bin:$LLVM_PREFIX/bin:\$PATH"
EOF

log "toolchain ready. Environment file: $INSTALL_ROOT/env.sh"
log "build with: scripts/macos/build-macos-native.sh --config build.json"
