#!/usr/bin/env bash
# Entry point for the Android builder image. Produces split-per-abi APKs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/customize.sh
. "$SCRIPT_DIR/customize.sh"

# Which ABIs to build. Comma separated in config as android_abis, default all.
ANDROID_ABIS_DEFAULT="arm64-v8a,armeabi-v7a,x86_64"

abi_to_target() {
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android arm64-v8a android-arm64 aarch64 ./flutter/ndk_arm64.sh" ;;
        armeabi-v7a) echo "armv7-linux-androideabi armeabi-v7a android-arm armv7 ./flutter/ndk_arm.sh" ;;
        x86_64)      echo "x86_64-linux-android x86_64 android-x64 x86_64 ./flutter/ndk_x64.sh" ;;
        *)           return 1 ;;
    esac
}

build_one_abi() {
    local abi="$1"
    local target ndk_abi flutter_plat arch ndk_script
    read -r target ndk_abi flutter_plat arch ndk_script <<<"$(abi_to_target "$abi")"

    report_status "Building native lib for ${abi}"
    export ANDROID_NDK_HOME="${ANDROID_NDK_HOME}" ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT}"
    try "$VCPKG_ROOT/vcpkg" >/dev/null 2>&1 || true
    try ./flutter/build_android_deps.sh "$ndk_abi"

    chmod +x "$ndk_script" 2>/dev/null || true
    "$ndk_script"

    local jni="./flutter/android/app/src/main/jniLibs/${ndk_abi}"
    mkdir -p "$jni"
    cp "./target/${target}/release/liblibrustdesk.so" "$jni/librustdesk.so"
    cp "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/${target%%-*}-linux-android"*/libc++_shared.so "$jni/" 2>/dev/null || \
    cp "${ANDROID_NDK_HOME}"/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/*/libc++_shared.so "$jni/" 2>/dev/null || true

    printf '%s' "${custom}" > ./flutter/assets/custom_.txt

    report_status "Building APK for ${abi}"
    (
        cd flutter
        # Use debug signing config unless the caller injected a real keystore.
        sed -i "s/signingConfigs.release/signingConfigs.debug/g" ./android/app/build.gradle || true
        sed -i "s/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/g" ./android/gradle.properties || true
        flutter build apk --release --target-platform "$flutter_plat" --split-per-abi
    )
    local out="$RD_OUT/${filename}-${arch}.apk"
    local built
    built="$(find ./flutter/build/app/outputs/flutter-apk -name "app-*-release.apk" | head -1)"
    [ -n "$built" ] || { warn "no apk produced for ${abi}"; return 0; }
    mv "$built" "$out"
    upload_artifact "$out"
}

main() {
    load_config
    mkdir -p "$RD_OUT"
    report_status "Preparing Android build environment"

    checkout_rustdesk
    cd "$RD_SRC"

    report_status "Applying customisations"
    customize_common
    customize_android
    apply_icon

    report_status "Generating flutter-rust bridge"
    generate_bridge

    export VCPKG_ROOT="${VCPKG_ROOT:-/opt/artifacts/vcpkg}"

    local abis="${android_abis:-$ANDROID_ABIS_DEFAULT}"
    IFS=',' read -ra abi_list <<<"$abis"
    for abi in "${abi_list[@]}"; do
        abi="$(echo "$abi" | tr -d ' ')"
        [ -n "$abi" ] || continue
        build_one_abi "$abi"
    done

    report_status "success"
    log "Android build finished. Artifacts in $RD_OUT:"
    ls -la "$RD_OUT" || true
}

main "$@"
