#!/usr/bin/env bash
# Entry point for the macOS build. Produces <filename>-<arch>.dmg and, when
# possible, uploads it to the rdgen server.
#
# Unlike the Linux/Android/Windows builds this one is NOT containerised: Apple's
# toolchain (Xcode, codesign, iconutil, hdiutil) only runs on macOS. It is meant
# to be driven by scripts/macos/build-macos-native.sh on a Mac or a macOS VM.
#
# Required in the environment (the wrapper sets them):
#   RD_WORK     work directory (holds the checkout and the output dir)
#   RD_CONFIG   path to build.json
#   RD_PATCHES  path to .github/patches
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/customize.sh
. "$SCRIPT_DIR/customize.sh"

# Deployment target used by the upstream workflow for Apple silicon.
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-12.3}"

# Rename the built bundle to the custom app name and return its directory.
find_app_bundle() {
    local dir
    for dir in \
        "$RD_SRC/flutter/build/macos/Build/Products/Release" \
        "$RD_SRC/build/macos/Build/Products/Release"; do
        [ -d "$dir" ] || continue
        if [ -d "$dir/RustDesk.app" ] && [ ! -d "$dir/${appname}.app" ]; then
            mv "$dir/RustDesk.app" "$dir/${appname}.app"
        fi
        if [ -d "$dir/${appname}.app" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

# Sign the bundle: with a .p12 if one is configured, ad-hoc otherwise. An
# unsigned bundle is refused by Gatekeeper, so ad-hoc is the minimum.
sign_app() {
    local app="$1"

    try xattr -cr "$app"

    if [ -n "${MACOS_P12_FILE:-}" ] && [ -f "${MACOS_P12_FILE}" ] && command -v rcodesign >/dev/null 2>&1; then
        log "signing with ${MACOS_P12_FILE}"
        local pw="${MACOS_P12_PASSWORD:-}"
        local main_exe="$app/Contents/MacOS/${appname}"
        [ -f "$main_exe" ] || main_exe="$(find "$app/Contents/MacOS" -maxdepth 1 -type f | head -n 1)"
        if [ -n "$main_exe" ]; then
            try rcodesign sign --p12-file "$MACOS_P12_FILE" --p12-password "$pw" \
                --code-signature-flags runtime "$main_exe"
        fi
        if [ -d "$app/Contents/Frameworks" ]; then
            find "$app/Contents/Frameworks" -type f -not -name ".*" -print0 |
                while IFS= read -r -d '' f; do
                    try rcodesign sign --p12-file "$MACOS_P12_FILE" --p12-password "$pw" \
                        --code-signature-flags runtime "$f"
                done
        fi
        try rcodesign sign --p12-file "$MACOS_P12_FILE" --p12-password "$pw" \
            --code-signature-flags runtime "$app"
        return 0
    fi

    log "ad-hoc signing (no MACOS_P12_FILE configured)"
    try codesign --force --deep --sign - "$app"
}

# create-dmg if available (nicer window layout), plain hdiutil otherwise.
make_dmg() {
    local release_dir="$1" dmg="$2"
    if command -v create-dmg >/dev/null 2>&1; then
        ( cd "$release_dir" && create-dmg \
            --volname "${appname}" \
            --window-pos 200 120 \
            --window-size 800 400 \
            --icon-size 100 \
            --icon "${appname}.app" 200 190 \
            --hide-extension "${appname}.app" \
            --app-drop-link 600 185 \
            "$dmg" "${appname}.app" ) && return 0
        warn "create-dmg failed, falling back to hdiutil"
    fi
    ( cd "$release_dir" && rm -f "$dmg" && hdiutil create -volname "${appname}" \
        -srcfolder "${appname}.app" -ov -format UDZO "$dmg" )
}

main() {
    [ "$(uname -s)" = "Darwin" ] || die "build-macos.sh must run on macOS (Apple toolchain required)"

    load_config
    mkdir -p "$RD_OUT"
    report_status "Preparing macOS build environment"

    for tool in flutter cargo python3 git; do
        command -v "$tool" >/dev/null 2>&1 || \
            die "$tool not found on PATH — run scripts/macos/setup-toolchain.sh first"
    done
    xcode-select -p >/dev/null 2>&1 || \
        die "Xcode command line tools missing — run: xcode-select --install"

    checkout_rustdesk
    cd "$RD_SRC"

    # `uname -m` says arm64, but the download links (and the macOS workflow)
    # name Apple silicon artifacts "aarch64" — keep the artifact naming aligned.
    local arch rust_target extra_build_args=""
    if [ "$(uname -m)" = "arm64" ]; then
        arch="aarch64"
        rust_target="aarch64-apple-darwin"
        # Upstream builds Apple silicon with ScreenCaptureKit support.
        extra_build_args="--screencapturekit"
    else
        arch="x86_64"
        rust_target="x86_64-apple-darwin"
    fi
    log "building for $arch ($rust_target)"

    report_status "Applying customisations"
    customize_common
    customize_macos
    apply_icon
    apply_icon_macos

    report_status "Generating flutter-rust bridge"
    generate_bridge

    report_status "Installing vcpkg dependencies"
    if [ -n "${VCPKG_ROOT:-}" ] && [ -x "$VCPKG_ROOT/vcpkg" ]; then
        try "$VCPKG_ROOT/vcpkg" install --x-install-root="$VCPKG_ROOT/installed"
    else
        warn "VCPKG_ROOT not set or vcpkg missing; the build may fail on libyuv/opus/ffmpeg"
    fi

    # Apple silicon needs a higher deployment target than the default.
    if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        tsed -e "s/MACOSX_DEPLOYMENT_TARGET\=[0-9]*.[0-9]*/MACOSX_DEPLOYMENT_TARGET=${MIN_MACOS_VERSION}/" build.py
        tsed -e "s/platform :osx, '.*'/platform :osx, '${MIN_MACOS_VERSION}'/" flutter/macos/Podfile
        tsed -e "s/osx_minimum_system_version = \"[0-9]*.[0-9]*\"/osx_minimum_system_version = \"${MIN_MACOS_VERSION}\"/" Cargo.toml
        tsed -e "s/MACOSX_DEPLOYMENT_TARGET = [0-9]*.[0-9]*;/MACOSX_DEPLOYMENT_TARGET = ${MIN_MACOS_VERSION};/" flutter/macos/Runner.xcodeproj/project.pbxproj
    fi

    report_status "Compiling RustDesk (this is the long part)"
    rustup target add "$rust_target" >/dev/null 2>&1 || true
    mkdir -p ./build/macos/Build/Products/Release
    # shellcheck disable=SC2086
    python3 ./build.py --flutter --hwcodec --unix-file-copy-paste $extra_build_args

    report_status "Packaging (.dmg)"
    local release_dir
    release_dir="$(find_app_bundle)" || die "no .app bundle produced — check the build log above"
    log "app bundle: $release_dir/${appname}.app"

    # Drop in the custom logo and icons into the built bundle
    local assets_dir="$release_dir/${appname}.app/Contents/Frameworks/App.framework/Versions/Current/Resources/flutter_assets/assets"
    mkdir -p "$assets_dir"
    if [ -f "./res/logo.png" ]; then
        cp "./res/logo.png" "$assets_dir/logo.png"
    fi
    if [ -f "./res/icon.png" ]; then
        cp "./res/icon.png" "$assets_dir/icon.png"
    fi
    if [ -f "./flutter/macos/Runner/AppIcon.icns" ]; then
        log "copying custom AppIcon.icns to app bundle resources"
        cp -f "./flutter/macos/Runner/AppIcon.icns" "$release_dir/${appname}.app/Contents/Resources/AppIcon.icns"
        cp -f "./flutter/macos/Runner/AppIcon.icns" "$release_dir/${appname}.app/Contents/Resources/icon.icns" 2>/dev/null || true
        touch "$release_dir/${appname}.app/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    fi
    touch "$release_dir/${appname}.app"


    sign_app "$release_dir/${appname}.app"

    local dmg="${filename}-${arch}.dmg"
    make_dmg "$release_dir" "$dmg" || die "could not create $dmg"
    mv "$release_dir/$dmg" "$RD_OUT/$dmg"

    report_status "Uploading artifacts"
    upload_artifact "$RD_OUT/$dmg"

    report_status "success"
    log "macOS build finished. Artifacts in $RD_OUT:"
    ls -la "$RD_OUT" || true
}

main "$@"
