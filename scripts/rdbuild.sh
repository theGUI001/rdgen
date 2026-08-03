#!/usr/bin/env bash
# rdbuild.sh - build customised RustDesk clients locally with Docker.
#
# This is the "easy button" for building without touching GitHub Actions: it
# builds (or pulls) the right builder image and runs the container against a
# build.json. It can schedule several platforms back-to-back in one invocation.
#
# Usage:
#   scripts/rdbuild.sh --config build.json --platforms linux,android
#   scripts/rdbuild.sh --config build.json --platforms linux --build-image
#   scripts/rdbuild.sh --platforms linux --appname Foo --filename foo --server rs.foo.com
#
# Notes:
#   * linux and android build on any Docker host (Linux containers).
#   * windows requires a Windows host with Windows containers enabled.
#   * macos / ios cannot be built in Docker (Apple toolchain needs macOS) and
#     are rejected with a clear message.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="${RDGEN_REGISTRY:-ghcr.io/${RDGEN_OWNER:-local}}"
IMAGE_TAG="${RDGEN_IMAGE_TAG:-latest}"
OUTPUT_DIR="${RDGEN_OUTPUT:-$REPO_ROOT/output}"

CONFIG=""
PLATFORMS=""
BUILD_IMAGE=0
declare -A OVERRIDES=()

usage() { sed -n '2,20p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)      usage 0 ;;
        --config)       CONFIG="$2"; shift 2 ;;
        --platforms)    PLATFORMS="$2"; shift 2 ;;
        --build-image)  BUILD_IMAGE=1; shift ;;
        --tag)          IMAGE_TAG="$2"; shift 2 ;;
        --output)       OUTPUT_DIR="$2"; shift 2 ;;
        --registry)     REGISTRY="$2"; shift 2 ;;
        # arbitrary config overrides, e.g. --appname Foo --server rs.foo.com
        --*)            OVERRIDES["${1#--}"]="$2"; shift 2 ;;
        *)              echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

[ -n "$PLATFORMS" ] || { echo "error: --platforms is required" >&2; usage 1; }
command -v docker >/dev/null || { echo "error: docker is not installed" >&2; exit 1; }

# Build the effective build.json = base config (if any) + CLI overrides.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
EFFECTIVE="$WORKDIR/build.json"

# Serialise overrides as a NUL-delimited key/value stream so any characters in
# values survive, then merge them onto the base config with python.
OVERRIDES_FILE="$WORKDIR/overrides.nul"
: > "$OVERRIDES_FILE"
for k in "${!OVERRIDES[@]}"; do
    printf '%s\0%s\0' "$k" "${OVERRIDES[$k]}" >> "$OVERRIDES_FILE"
done

MERGE_PY="$WORKDIR/merge.py"
cat > "$MERGE_PY" <<'PY'
import json, sys
base_path, out_path, overrides_path = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {}
if base_path:
    with open(base_path) as fh:
        cfg = json.load(fh)
with open(overrides_path, "rb") as fh:
    raw = fh.read().split(b"\0")
if raw and raw[-1] == b"":
    raw = raw[:-1]
for i in range(0, len(raw) - 1, 2):
    cfg[raw[i].decode()] = raw[i + 1].decode()
with open(out_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
PY
python3 "$MERGE_PY" "$CONFIG" "$EFFECTIVE" "$OVERRIDES_FILE"

mkdir -p "$OUTPUT_DIR"

image_for() {
    case "$1" in
        linux)   echo "rdgen-linux-builder" ;;
        android) echo "rdgen-android-builder" ;;
        windows) echo "rdgen-windows-builder" ;;
    esac
}

dockerfile_for() {
    case "$1" in
        linux)   echo "docker/linux-builder.Dockerfile" ;;
        android) echo "docker/android-builder.Dockerfile" ;;
        windows) echo "docker/windows-builder.Dockerfile" ;;
    esac
}

build_platform() {
    local platform="$1"
    case "$platform" in
        macos|ios)
            echo "==> SKIP $platform: Apple platforms require a macOS host and cannot be built in Docker." >&2
            echo "    Use the GitHub Actions macOS runner (generator-macos.yml) for these targets." >&2
            return 2
            ;;
        linux|android|windows) ;;
        *) echo "==> SKIP $platform: unknown platform" >&2; return 2 ;;
    esac

    local image dockerfile
    image="$REGISTRY/$(image_for "$platform"):$IMAGE_TAG"
    dockerfile="$REPO_ROOT/$(dockerfile_for "$platform")"

    if [ "$BUILD_IMAGE" -eq 1 ]; then
        echo "==> Building image $image"
        docker build -f "$dockerfile" -t "$image" "$REPO_ROOT"
    elif ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "==> Pulling image $image"
        if ! docker pull "$image"; then
            echo "==> Image not available, building locally"
            docker build -f "$dockerfile" -t "$image" "$REPO_ROOT"
        fi
    fi

    # Per-platform config: force the platform field.
    local pcfg="$WORKDIR/build-$platform.json"
    python3 - "$EFFECTIVE" "$pcfg" "$platform" <<'PY'
import json, sys
src, dst, platform = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fh: cfg = json.load(fh)
cfg["platform"] = platform
with open(dst, "w") as fh: json.dump(cfg, fh, indent=2)
PY

    local pout="$OUTPUT_DIR/$platform"
    mkdir -p "$pout"
    echo "==> Running $platform build (output -> $pout)"

    if [ "$platform" = "windows" ]; then
        docker run --rm \
            -v "${pcfg}:C:/work/build.json:ro" \
            -v "${pout}:C:/work/output" \
            "$image"
    else
        docker run --rm \
            -v "${pcfg}:/work/build.json:ro" \
            -v "${pout}:/work/output" \
            "$image"
    fi
}

echo "==> Scheduling builds: $PLATFORMS"
declare -A RESULTS=()
IFS=',' read -ra plist <<<"$PLATFORMS"
for platform in "${plist[@]}"; do
    platform="$(echo "$platform" | tr -d ' ')"
    [ -n "$platform" ] || continue
    if build_platform "$platform"; then
        RESULTS[$platform]="ok"
    else
        [ $? -eq 2 ] && RESULTS[$platform]="skipped" || RESULTS[$platform]="FAILED"
    fi
done

echo ""
echo "==================== build summary ===================="
for platform in "${!RESULTS[@]}"; do
    printf '  %-10s %s\n' "$platform" "${RESULTS[$platform]}"
done
echo "  artifacts in: $OUTPUT_DIR"
echo "======================================================="
