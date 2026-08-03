#!/usr/bin/env bash
# Entry point for the Linux builder image. Produces .deb and .rpm packages for
# the current architecture and (optionally) uploads them to the rdgen server.
#
#   docker run --rm -v "$PWD/out:/work/output" -v "$PWD/build.json:/work/build.json" \
#       ghcr.io/<owner>/rdgen-linux-builder:latest
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/customize.sh
. "$SCRIPT_DIR/customize.sh"

main() {
    load_config
    mkdir -p "$RD_OUT"
    report_status "Preparing Linux build environment"

    checkout_rustdesk
    cd "$RD_SRC"

    report_status "Applying customisations"
    # Build only the cdylib, like generator-linux.yml.
    tsed 's/\["cdylib", "staticlib", "rlib"\]/["cdylib"]/g' Cargo.toml
    customize_common
    apply_icon

    report_status "Generating flutter-rust bridge"
    generate_bridge

    local arch triplet
    arch="$(uname -m)"
    triplet="$(cat /opt/artifacts/vcpkg-triplet 2>/dev/null || echo x64-linux)"

    report_status "Installing vcpkg dependencies"
    export VCPKG_ROOT="${VCPKG_ROOT:-/opt/artifacts/vcpkg}"
    try "$VCPKG_ROOT/vcpkg" install --triplet "$triplet" \
        --x-install-root="$VCPKG_ROOT/installed"

    # Make the systemd unit follow the custom binary name.
    tsed -e "s|\(systemctl\s\+\S\+\s\)rustdesk|\1${filename}|g" src/platform/linux.rs || true

    report_status "Compiling RustDesk (this is the long part)"
    export CARGO_INCREMENTAL=0
    cargo build --lib --features hwcodec,flutter,unix-file-copy-paste --release
    rm -rf target/release/deps target/release/build

    report_status "Packaging (.deb / .rpm)"
    mkdir -p flutter/tmpdeb/usr/share/rustdesk
    cp ./custom_.txt ./flutter/tmpdeb/usr/share/rustdesk/custom_.txt

    if [ "${logolink_url}" != "false" ] && [ -n "${logolink_url}" ]; then
        fetch_png "${logolink_url}" "${logolink_file:-logo.png}" "${logolink_uuid:-$uuid}" \
            ./flutter/assets/logo.png || true
    fi
    if [ "${iconlink_url}" != "false" ] && [ -n "${iconlink_url}" ]; then
        (
            cd ./flutter
            flutter pub get && dart run flutter_launcher_icons || true
        )
    fi

    python3 ./build.py --flutter --skip-cargo

    for name in *.deb; do
        [ -e "$name" ] || continue
        mv "$name" "$RD_OUT/${filename}-${arch}.deb"
    done

    # rpm (fedora). Best-effort: not every version ships the spec.
    if [ -f ./res/rpm-flutter.spec ]; then
        HBB="$(pwd)" try rpmbuild ./res/rpm-flutter.spec -bb
        if [ -d "$HOME/rpmbuild/RPMS/$arch" ]; then
            for name in "$HOME/rpmbuild/RPMS/$arch"/*.rpm; do
                [ -e "$name" ] || continue
                mv "$name" "$RD_OUT/${filename}-${arch}.rpm"
            done
        fi
    fi

    report_status "Uploading artifacts"
    upload_artifact "$RD_OUT/${filename}-${arch}.deb"
    upload_artifact "$RD_OUT/${filename}-${arch}.rpm"

    report_status "success"
    log "Linux build finished. Artifacts in $RD_OUT:"
    ls -la "$RD_OUT" || true
}

main "$@"
