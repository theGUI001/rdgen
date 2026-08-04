#!/usr/bin/env bash
# Applies every source-level customisation to a RustDesk checkout.
#
# This is the shell equivalent of the "change appname / change url / allow
# custom.txt / ..." steps that were duplicated across generator-linux.yml,
# generator-android.yml and generator-windows.yml. Keeping it in one file means
# a fix to the whitelabelling logic lands for every platform at once.
#
# Expects the config already loaded into the environment (load_config) and the
# working directory to be the RustDesk source tree.
set -u

# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

customize_common() {
    log "applying common customisations"

    # --- server / key / api endpoint ---------------------------------------
    tsed -e "s|rs-ny.rustdesk.com|${server}|" ./libs/hbb_common/src/config.rs
    tsed -e "s|OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=|${key}|" ./libs/hbb_common/src/config.rs
    tsed -e "s|https://admin.rustdesk.com|${apiServer}|" ./src/common.rs

    # --- allow custom.txt (bypass signature check) -------------------------
    local allow
    if allow="$(patch_path allowCustom.py)"; then
        try python3 "$allow"
    else
        # Fallback: strip the embedded KEY + verify block directly.
        tsed -e '/const KEY:/,/};/d' ./src/common.rs
        tsed -e '/let Ok(data) = sign::verify(&data, &pk)/,/};/d' ./src/common.rs
    fi
    local rmtip
    if rmtip="$(patch_path removeSetupServerTip.diff)"; then
        try git apply "$rmtip"
    fi
    printf '%s' "${custom}" > ./custom_.txt

    # --- app name / whitelabel ---------------------------------------------
    if [ "${appname}" != "rustdesk" ]; then
        log "renaming app to '${appname}'"
        tsed -e "s|description = \"RustDesk Remote Desktop\"|description = \"${appname}\"|" ./Cargo.toml
        tsed -e "s|ProductName = \"RustDesk\"|ProductName = \"${appname}\"|" ./Cargo.toml
        tsed -e "s|FileDescription = \"RustDesk Remote Desktop\"|FileDescription = \"${appname}\"|" ./Cargo.toml
        tsed -e "s|OriginalFilename = \"rustdesk.exe\"|OriginalFilename = \"${appname}.exe\"|" ./Cargo.toml
        tsed -e "s|description = \"RustDesk Remote Desktop\"|description = \"${appname}\"|" ./libs/portable/Cargo.toml
        tsed -e "s|ProductName = \"RustDesk\"|ProductName = \"${appname}\"|" ./libs/portable/Cargo.toml
        tsed -e "s|FileDescription = \"RustDesk Remote Desktop\"|FileDescription = \"${appname}\"|" ./libs/portable/Cargo.toml
        tsed -e "s|OriginalFilename = \"rustdesk.exe\"|OriginalFilename = \"${appname}.exe\"|" ./libs/portable/Cargo.toml
        tsed -e "s|const APP_PREFIX: &str = \"rustdesk\";|const APP_PREFIX: \&str = \"${appname}\";|" ./libs/portable/src/main.rs
        try find ./src/lang -name "*.rs" -exec sed -i -e "s|RustDesk|${appname}|" {} \;
    fi

    # --- company name -------------------------------------------------------
    if [ "${compname}" != "Purslane Ltd" ]; then
        log "setting company name to '${compname}'"
        for f in \
            ./flutter/lib/desktop/pages/desktop_setting_page.dart \
            ./Cargo.toml ./libs/portable/Cargo.toml ./src/ui/index.tis ./src/main.rs; do
            [ -f "$f" ] || continue
            tsed -e "s|Purslane Tech Pte. Ltd.|${compname}|" "$f"
            tsed -e "s|Purslane Ltd.|${compname}|" "$f"
            tsed -e "s|Purslane Ltd|${compname}|" "$f"
        done
    fi

    # --- custom URLs --------------------------------------------------------
    if [ "${urlLink}" != "https://rustdesk.com" ]; then
        log "setting homepage url to ${urlLink}"
        tsed -e "s|Homepage: https://rustdesk.com|Homepage: ${urlLink}|" ./build.py
        tsed -e "s|launchUrl(Uri.parse('https://rustdesk.com'));|launchUrl(Uri.parse('${urlLink}'));|" ./flutter/lib/common.dart
        tsed -e "s|launchUrlString('https://rustdesk.com');|launchUrlString('${urlLink}');|" ./flutter/lib/desktop/pages/desktop_setting_page.dart
        tsed -e "s|launchUrlString('https://rustdesk.com/privacy.html')|launchUrlString('${urlLink}/privacy.html')|" ./flutter/lib/desktop/pages/desktop_setting_page.dart
        tsed -e "s|const url = 'https://rustdesk.com/';|const url = '${urlLink}';|" ./flutter/lib/mobile/pages/settings_page.dart
        tsed -e "s|launchUrlString('https://rustdesk.com/privacy.html')|launchUrlString('${urlLink}/privacy.html')|" ./flutter/lib/mobile/pages/settings_page.dart
        tsed -e "s|https://rustdesk.com/privacy.html|${urlLink}/privacy.html|" ./flutter/lib/desktop/pages/install_page.dart
    fi

    if [ "${downloadLink}" != "https://rustdesk.com/download" ]; then
        log "setting download url to ${downloadLink}"
        tsed -e "s|https://rustdesk.com/download|${downloadLink}|" ./flutter/lib/desktop/pages/desktop_home_page.dart
        tsed -e "s|https://rustdesk.com/download|${downloadLink}|" ./flutter/lib/mobile/pages/connection_page.dart
        tsed -e "s|https://rustdesk.com/download|${downloadLink}|" ./src/ui/index.tis
    fi

    # --- feature toggles ----------------------------------------------------
    if [ "${delayFix}" = "true" ]; then
        log "applying connection delay fix"
        tsed -e 's|!key.is_empty()|false|' ./src/client.rs
    fi

    if [ "${xOffline}" = "true" ]; then
        local p
        if p="$(patch_path xoffline.diff)"; then
            log "applying xOffline patch"
            try git apply "$p"
        fi
    fi

    if [ "${hidecm}" = "true" ]; then
        local p
        if p="$(patch_path hidecm.diff)"; then
            log "applying hide-cm patch"
            try git apply "$p"
        fi
    fi

    if [ "${removeNewVersionNotif}" = "true" ]; then
        log "removing new-version notification"
        tsed -e 's|updateUrl.isNotEmpty|false|' ./flutter/lib/desktop/pages/desktop_home_page.dart
        tsed -e '/let (request, url) =/,/Ok(())/{/Ok(())/!d}' ./src/common.rs
    fi
}

# Android-specific renames (labels, kotlin sources, app id).
customize_android() {
    log "applying android customisations"
    if [ "${appname}" != "rustdesk" ]; then
        tsed -e "s|RustDesk|${appname}|" ./flutter/android/app/src/main/res/values/strings.xml
        tsed -e "s|title: 'RustDesk'|title: '${appname}'|" ./flutter/lib/main.dart
        tsed -e "s|return 'RustDesk';|return '${appname}';|" ./flutter/lib/web/bridge.dart
        tsed -e "s|android:label=\"RustDesk\"|android:label=\"${appname}\"|" ./flutter/android/app/src/main/AndroidManifest.xml
        tsed -e "s|android:label=\"RustDesk Input\"|android:label=\"${appname} Input\"|" ./flutter/android/app/src/main/AndroidManifest.xml
        tsed -e "s|RustDesk is Open|${appname} is Open|" ./flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/BootReceiver.kt
        tsed -e "s|Show Rustdesk|Show ${appname}|" ./flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/FloatingWindowService.kt
        tsed -e "s|\"RustDesk\"|\"${appname}\"|" ./flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt
        tsed -e "s|\"RustDesk Service|\"${appname} Service|" ./flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt
        tsed -e "s|RustDesk|${appname}|" ./flutter/lib/main.dart
        tsed -e "s|\"RustDesk\"|\"${appname}\"|" ./flutter/lib/desktop/widgets/tabbar_widget.dart
        tsed -e "s|\"RustDesk\"|\"${appname}\"|" ./libs/hbb_common/src/config.rs
    fi
    if [ "${androidappid}" != "com.carriez.flutter_hbb" ]; then
        log "setting android application id to ${androidappid}"
        tsed -e "s|com.carriez.flutter_hbb|${androidappid}|" ./flutter/android/app/build.gradle
    fi
    # Silence the "scam warning" prompt, same as generator-android.yml.
    tsed -e 's/bind.mainGetLocalOption(key:\s*"show-scam-warning")/"N"/g' ./flutter/lib/mobile/pages/server_page.dart
}

# Replace the app icon from a downloaded PNG. base_url/file/uuid come from config.
apply_icon() {
    [ "${iconlink_url}" != "false" ] && [ -n "${iconlink_url}" ] || return 0
    command -v convert >/dev/null 2>&1 || { warn "imagemagick missing, skipping icon"; return 0; }
    fetch_png "${iconlink_url}" "${iconlink_file:-icon.png}" "${iconlink_uuid:-$uuid}" ./res/icon.png || return 0
    log "regenerating icon assets"
    try convert ./res/icon.png -define icon:auto-resize=256,64,48,32,16 ./res/icon.ico
    try cp ./res/icon.ico ./res/tray-icon.ico
    try convert ./res/icon.png -resize 32x32 ./res/32x32.png
    try convert ./res/icon.png -resize 64x64 ./res/64x64.png
    try convert ./res/icon.png -resize 128x128 ./res/128x128.png
    try convert ./res/128x128.png -resize 200% ./res/128x128@2x.png
}
