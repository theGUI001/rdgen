#!/usr/bin/env bash
# Shared helpers for the containerised RustDesk builds.
#
# Everything the build needs comes from a single build.json (see
# scripts/config.example.json). Each key becomes an environment variable, which
# keeps the customisation logic identical whether it runs in GitHub Actions or
# on a laptop with plain `docker run`.

RDGEN_ROOT="${RDGEN_ROOT:-/opt/rdgen}"
RD_WORK="${RD_WORK:-/work}"
RD_SRC="${RD_SRC:-$RD_WORK/rustdesk}"
RD_OUT="${RD_OUT:-$RD_WORK/output}"
RD_PATCHES="${RD_PATCHES:-$RDGEN_ROOT/patches}"

log()  { printf '\033[1;34m[rdgen]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[rdgen]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[rdgen]\033[0m %s\n' "$*" >&2; exit 1; }

# Best-effort step: the upstream workflows mark most customisation steps
# continue-on-error, because a sed that no longer matches must not fail a build.
try() {
    if ! "$@"; then
        warn "step failed (ignored): $*"
        return 0
    fi
}

# sed -i that never fails the build.
tsed() { try sed -i "$@"; }

# Reads build.json and exports every key as an environment variable.
load_config() {
    local config="${1:-${RD_CONFIG:-$RD_WORK/build.json}}"
    [ -f "$config" ] || die "config not found: $config (see scripts/config.example.json)"

    local exports
    exports="$(python3 - "$config" <<'PY'
import json, shlex, sys

with open(sys.argv[1]) as fh:
    cfg = json.load(fh)

for key, value in cfg.items():
    if isinstance(value, bool):
        value = 'true' if value else 'false'
    elif value is None:
        value = ''
    print("export %s=%s" % (key, shlex.quote(str(value))))
PY
)" || die "could not parse $config"
    eval "$exports"

    # Defaults, mirroring rdgenerator/views.py.
    : "${platform:=linux}"
    : "${version:=master}"
    : "${server:=rs-ny.rustdesk.com}"
    : "${key:=OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=}"
    : "${apiServer:=${server}:21114}"
    : "${appname:=rustdesk}"
    : "${filename:=rustdesk}"
    : "${compname:=Purslane Ltd}"
    : "${androidappid:=com.carriez.flutter_hbb}"
    : "${urlLink:=https://rustdesk.com}"
    : "${downloadLink:=https://rustdesk.com/download}"
    : "${custom:=}"
    : "${uuid:=local}"
    : "${delayFix:=true}"
    : "${xOffline:=false}"
    : "${hidecm:=false}"
    : "${removeNewVersionNotif:=false}"
    : "${rdgen:=false}"
    : "${iconlink_url:=false}"
    : "${logolink_url:=false}"
    : "${privacylink_url:=false}"
    : "${upload_url:=}"
    : "${status_url:=}"
    : "${token:=}"

    export platform version server key apiServer appname filename compname \
           androidappid urlLink downloadLink custom uuid delayFix xOffline \
           hidecm removeNewVersionNotif rdgen iconlink_url logolink_url \
           privacylink_url upload_url status_url token

    log "platform=$platform version=$version appname=$appname filename=$filename"
}

# Push a human readable status back to the rdgen server, if one is configured.
report_status() {
    local status="$1"
    log "status: $status"
    [ -n "$status_url" ] || return 0
    try curl -sS -m 30 -X POST -H "Content-Type: application/json" \
        -d "{\"uuid\": \"${uuid}\", \"status\": \"${status}\"}" \
        "$status_url" >/dev/null
}

# Upload one built artifact back to the rdgen server, if one is configured.
upload_artifact() {
    local file="$1"
    [ -f "$file" ] || { warn "nothing to upload at $file"; return 0; }
    if [ -z "$upload_url" ]; then
        log "built $(basename "$file") (no upload_url set, leaving it in $RD_OUT)"
        return 0
    fi
    local attempt
    for attempt in 1 2 3; do
        if curl -sS -f -m 900 -X POST \
              -H "Authorization: Bearer ${token}" \
              -F "file=@${file}" -F "uuid=${uuid}" "$upload_url" >/dev/null; then
            log "uploaded $(basename "$file")"
            return 0
        fi
        warn "upload of $(basename "$file") failed (attempt $attempt/3)"
        sleep $((attempt * 10))
    done
    warn "giving up on uploading $(basename "$file")"
}

# Download one of the PNGs the user uploaded to the rdgen server.
fetch_png() {
    local base_url="$1" file="$2" png_uuid="$3" dest="$4"
    [ "$base_url" != "false" ] && [ -n "$base_url" ] || return 1
    local attempt
    for attempt in 1 2 3; do
        if curl -sS -f -m 60 -o "$dest" \
              "${base_url}/get_png?filename=${file}&uuid=${png_uuid}"; then
            return 0
        fi
        sleep $((attempt * 5))
    done
    warn "could not download $dest from $base_url"
    return 1
}

# Clone (or reuse) the RustDesk sources at the requested version.
checkout_rustdesk() {
    git config --global --add safe.directory '*' || true

    if [ -d "$RD_SRC/.git" ]; then
        log "reusing existing checkout at $RD_SRC"
        return 0
    fi

    log "cloning rustdesk@${version}"
    if [ "$version" = "master" ]; then
        git clone --depth 1 --recurse-submodules --shallow-submodules \
            https://github.com/rustdesk/rustdesk "$RD_SRC"
    else
        git clone --depth 1 --branch "$version" --recurse-submodules --shallow-submodules \
            https://github.com/rustdesk/rustdesk "$RD_SRC"
    fi
}

# flutter_rust_bridge codegen. The upstream workflows do this in a separate CI
# job and pass the result around as an artifact; in a container we just run it.
generate_bridge() {
    if [ -f "$RD_SRC/src/bridge_generated.rs" ] && [ -f "$RD_SRC/flutter/lib/generated_bridge.dart" ]; then
        log "bridge files already present, skipping codegen"
        return 0
    fi
    log "generating flutter_rust_bridge files"
    (
        cd "$RD_SRC/flutter" || die "flutter dir missing"
        try sed -i -e 's/extended_text: 14.0.0/extended_text: 13.0.0/g' pubspec.yaml
        flutter pub get
    )
    (
        cd "$RD_SRC" || die "source dir missing"
        flutter_rust_bridge_codegen \
            --rust-input ./src/flutter_ffi.rs \
            --dart-output ./flutter/lib/generated_bridge.dart \
            --c-output ./flutter/macos/Runner/bridge_generated.h
        try cp ./flutter/macos/Runner/bridge_generated.h ./flutter/ios/Runner/bridge_generated.h
    )
}

# Locate a patch, preferring the copy baked into the image.
patch_path() {
    local name="$1"
    if [ -f "$RD_PATCHES/$name" ]; then
        printf '%s\n' "$RD_PATCHES/$name"
        return 0
    fi
    local dest="/tmp/$name"
    if curl -sS -f -m 60 -o "$dest" \
        "https://raw.githubusercontent.com/bryangerlach/rdgen/refs/heads/master/.github/patches/$name"; then
        printf '%s\n' "$dest"
        return 0
    fi
    return 1
}
