#!/usr/bin/env bash
# Build a customised RustDesk macOS client natively (no Docker).
#
# Intended for a Mac or a macOS VM (UTM / Parallels / tart on Apple hardware).
# It prepares a work directory and then reuses the shared build logic in
# scripts/build-macos.sh, which discovers the toolchain on PATH. Produces
# <filename>-<arch>.dmg in the output directory.
#
# Run scripts/macos/setup-toolchain.sh once first (or pass --setup here).
#
# Usage:
#   scripts/macos/build-macos-native.sh --config build.json [--output ./output]
#   scripts/macos/build-macos-native.sh --config build.json --setup
#
# Options:
#   -c, --config FILE     build.json to build from (required)
#   -o, --output DIR      where to place the .dmg (default ./output/macos)
#   -w, --work DIR        work directory (default a fresh dir under TMPDIR)
#       --install-root D  toolchain root used by setup (default ~/rdgen-tools)
#       --setup           run setup-toolchain.sh before building
#   -h, --help            this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG=""
OUTPUT="$PWD/output/macos"
WORKDIR=""
INSTALL_ROOT="${RDGEN_INSTALL_ROOT:-$HOME/rdgen-tools}"
RUN_SETUP=0

usage() { sed -n '2,24p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)         usage 0 ;;
        -c|--config)       CONFIG="$2"; shift 2 ;;
        -o|--output)       OUTPUT="$2"; shift 2 ;;
        -w|--work)         WORKDIR="$2"; shift 2 ;;
        --install-root)    INSTALL_ROOT="$2"; shift 2 ;;
        --setup)           RUN_SETUP=1; shift ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

log() { printf '\033[1;32m[rdgen-native]\033[0m %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || {
    echo "error: this script must run on macOS. Apple's toolchain cannot build in Docker." >&2
    exit 1
}
[ -n "$CONFIG" ] || { echo "error: --config is required" >&2; usage 1; }
[ -f "$CONFIG" ] || { echo "error: config not found: $CONFIG" >&2; exit 1; }

if [ "$RUN_SETUP" -eq 1 ]; then
    log "running toolchain setup..."
    "$SCRIPT_DIR/setup-toolchain.sh" --install-root "$INSTALL_ROOT"
fi

# Pull in the toolchain env if setup produced one (harmless if absent).
ENV_FILE="$INSTALL_ROOT/env.sh"
if [ -f "$ENV_FILE" ]; then
    log "loading toolchain env from $ENV_FILE"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

if [ -z "$WORKDIR" ]; then
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rdgen-XXXXXXXX")"
fi
mkdir -p "$WORKDIR" "$OUTPUT"
cp "$CONFIG" "$WORKDIR/build.json"

export RD_WORK="$WORKDIR"
export RD_CONFIG="$WORKDIR/build.json"
export RD_PATCHES="$REPO_ROOT/.github/patches"

log "work dir: $WORKDIR"
log "starting native macOS build (this takes a while)..."

build_exit=0
"$REPO_ROOT/scripts/build-macos.sh" || build_exit=$?

PRODUCED="$WORKDIR/output"
if [ -d "$PRODUCED" ]; then
    cp -R "$PRODUCED/." "$OUTPUT/" 2>/dev/null || true
fi

if [ "$build_exit" -ne 0 ]; then
    log "build reported a non-zero exit ($build_exit). Check the output above."
    exit "$build_exit"
fi

log "done. Artifacts in: $OUTPUT"
ls -la "$OUTPUT" || true
