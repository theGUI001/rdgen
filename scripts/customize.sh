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

    # Patch scrap build.rs to include cfg in regex and use bindgen CLI if available
    if [ -f ./libs/scrap/build.rs ]; then
        python3 -c "
f = './libs/scrap/build.rs'
c = open(f).read()
c = c.replace('^(aom|AOM|OBU|AV1).*', '^(aom|AOM|OBU|AV1|cfg).*')
old_fn = '''fn generate_bindings(
    ffi_header: &Path,
    include_paths: &[PathBuf],
    ffi_rs: &Path,
    exact_file: &Path,
    regex: &str,
) {'''
new_fn = '''fn generate_bindings(
    ffi_header: &Path,
    include_paths: &[PathBuf],
    ffi_rs: &Path,
    exact_file: &Path,
    regex: &str,
) {
    let mut cmd = std::process::Command::new(\"bindgen\");
    cmd.arg(ffi_header)
       .arg(\"--allowlist-type\").arg(regex)
       .arg(\"--allowlist-var\").arg(regex)
       .arg(\"--allowlist-function\").arg(regex)
       .arg(\"--rustified-enum\").arg(regex)
       .arg(\"--output\").arg(ffi_rs)
       .arg(\"--no-layout-tests\")
       .arg(\"--no-doc-comments\")
       .arg(\"--\");
    for dir in include_paths {
        cmd.arg(format!(\"-I{}\", dir.display()));
    }
    if let Ok(status) = cmd.status() {
        if status.success() {
            fs::copy(ffi_rs, exact_file).ok();
            return;
        }
    }'''
c = c.replace(old_fn, new_fn)
open(f, 'w').write(c)
"
    fi

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
        for lang_file in ./src/lang/*.rs; do
            [ -f "$lang_file" ] || continue
            tsed -e "s|RustDesk|${appname}|" "$lang_file"
        done
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

ensure_icon() {
    mkdir -p ./res
    local raw_icon="${iconfile:-${iconbase64:-}}"
    if [ -n "$raw_icon" ] && [ "$raw_icon" != "false" ]; then
        log "extracting custom icon from base64"
        python3 -c "
import os, base64
s = os.environ.get('iconfile') or os.environ.get('iconbase64') or ''
if ',' in s:
    s = s.split(',', 1)[1]
if s.strip():
    with open('./res/icon.png', 'wb') as f:
        f.write(base64.b64decode(s.strip()))
" || { warn "failed to decode icon base64"; return 1; }
    elif [ "${iconlink_url:-false}" != "false" ] && [ -n "${iconlink_url:-}" ]; then
        fetch_png "${iconlink_url}" "${iconlink_file:-icon.png}" "${iconlink_uuid:-$uuid}" ./res/icon.png || return 1
    fi
    [ -f ./res/icon.png ]
}

ensure_logo() {
    mkdir -p ./res
    local raw_logo="${logofile:-${logobase64:-}}"
    if [ -n "$raw_logo" ] && [ "$raw_logo" != "false" ]; then
        log "extracting custom logo from base64"
        python3 -c "
import os, base64
s = os.environ.get('logofile') or os.environ.get('logobase64') or ''
if ',' in s:
    s = s.split(',', 1)[1]
if s.strip():
    with open('./res/logo.png', 'wb') as f:
        f.write(base64.b64decode(s.strip()))
" || { warn "failed to decode logo base64"; return 1; }
    elif [ "${logolink_url:-false}" != "false" ] && [ -n "${logolink_url:-}" ]; then
        fetch_png "${logolink_url}" "${logolink_file:-logo.png}" "${logolink_uuid:-$uuid}" ./res/logo.png || return 1
    elif [ -f ./res/icon.png ]; then
        cp ./res/icon.png ./res/logo.png
    fi
    [ -f ./res/logo.png ]
}

# Replace the app icon from a downloaded PNG or base64.
apply_icon() {
    ensure_icon || return 0
    local im
    im="$(magick_bin)" || { warn "imagemagick missing, skipping icon"; return 0; }
    log "regenerating icon assets"
    try "$im" ./res/icon.png -define icon:auto-resize=256,64,48,32,16 ./res/icon.ico
    try cp ./res/icon.ico ./res/tray-icon.ico
    try "$im" ./res/icon.png -resize 32x32 ./res/32x32.png
    try "$im" ./res/icon.png -resize 64x64 ./res/64x64.png
    try "$im" ./res/icon.png -resize 128x128 ./res/128x128.png
    try "$im" ./res/128x128.png -resize 200% ./res/128x128@2x.png
}


# macOS-specific whitelabelling: bundle metadata (Info.plist, xcconfig, Xcode
# project), the Flutter binary name and the About/slogan strings. Mirrors the
# "Update macOS Info.plist and settings" step of generator-macos.yml.
customize_macos() {
    log "applying macOS customisations"

    # A CFBundleIdentifier may only contain alphanumerics, '-' and '.', so an
    # app name with spaces or accents has to be squeezed first — otherwise the
    # bundle is rejected at codesign time.
    local bundle_slug
    bundle_slug="$(printf '%s' "${appname}" | tr -cd '[:alnum:]-')"
    [ -n "$bundle_slug" ] || bundle_slug="rustdesk"
    local bundle_id="com.${bundle_slug}.app"
    log "bundle identifier: ${bundle_id}"

    if [ "${appname}" != "rustdesk" ]; then
        # Info.plist keys and their <string> live on separate lines, so a plain
        # sed does not match; rewrite the value that follows each key instead.
        try python3 - ./flutter/macos/Runner/Info.plist "${appname}" "${bundle_id}" <<'PY'
import re, sys

path, appname, bundle_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    plist = fh.read()

for key, value in (
    ("CFBundleName", appname),
    ("CFBundleDisplayName", appname),
    ("CFBundleIdentifier", bundle_id),
):
    plist = re.sub(
        r"(<key>%s</key>\s*<string>)[^<]*(</string>)" % key,
        lambda m: m.group(1) + value + m.group(2),
        plist,
    )

with open(path, "w") as fh:
    fh.write(plist)
PY

        tsed -e "s|PRODUCT_NAME = .*|PRODUCT_NAME = ${appname}|" \
            ./flutter/macos/Runner/Configs/AppInfo.xcconfig
        tsed -e "s|PRODUCT_BUNDLE_IDENTIFIER = .*|PRODUCT_BUNDLE_IDENTIFIER = ${bundle_id}|" \
            ./flutter/macos/Runner/Configs/AppInfo.xcconfig

        # Xcode project: product name + bundle id (DEVELOPMENT_TEAM is left alone).
        tsed -e "s/PRODUCT_NAME = \"RustDesk\"/PRODUCT_NAME = \"${appname}\"/" \
            ./flutter/macos/Runner.xcodeproj/project.pbxproj
        tsed -e "s/PRODUCT_BUNDLE_IDENTIFIER = \".*\"/PRODUCT_BUNDLE_IDENTIFIER = \"${bundle_id}\"/" \
            ./flutter/macos/Runner.xcodeproj/project.pbxproj

        if [ -f ./flutter/macos/CMakeLists.txt ]; then
            tsed -e "s/set(BINARY_NAME \".*\")/set(BINARY_NAME \"${appname}\")/" \
                ./flutter/macos/CMakeLists.txt
        fi

        # build.py packages "RustDesk.app"; point it at the renamed bundle.
        tsed -e "s/RustDesk.app/\"${appname}.app\"/" ./build.py

        # About / slogan strings (en + nl, like the workflow).
        tsed -e "s/(\"Slogan_tip\", \"Made with heart in this chaotic world!\")/(\"Slogan_tip\", \"Powered by ${appname}\")/" ./src/lang/en.rs
        tsed -e "s/(\"About RustDesk\", \"\")/(\"About RustDesk\", \"About ${appname}\")/" ./src/lang/en.rs
        tsed -e "s/(\"Slogan_tip\", \"Ontwikkeld met het hart voor deze chaotische wereld!\")/(\"Slogan_tip\", \"Powered by ${appname}\")/" ./src/lang/nl.rs
        tsed -e "s/(\"About RustDesk\", \"Over RustDesk\")/(\"About RustDesk\", \"Over ${appname}\")/" ./src/lang/nl.rs
    fi

    if [ "${compname}" != "Purslane Ltd" ]; then
        tsed -e "s|Purslane Tech Pte. Ltd.|${compname}|" ./flutter/macos/Runner/Configs/AppInfo.xcconfig
        tsed -e "s|Purslane Ltd.|${compname}|" ./flutter/macos/Runner/Configs/AppInfo.xcconfig
    fi

    # The download-link rewrites the macOS workflow does on top of the common set.
    if [ "${downloadLink}" != "https://rustdesk.com/download" ]; then
        tsed -e "s|&download_url|\"${downloadLink}\"|" ./src/updater.rs
        tsed -e "s|\$downloadUrl/\$downloadFile|${downloadLink}|" ./flutter/lib/desktop/widgets/update_progress.dart
    fi

    # `archive` is needed by the macOS Flutter build and is not in pubspec.
    if ! grep -q '^  archive:' ./flutter/pubspec.yaml 2>/dev/null; then
        try awk '/^  intl:/{print; print "  archive: ^3.6.1"; next} 1' \
            ./flutter/pubspec.yaml > ./flutter/pubspec.yaml.tmp \
            && mv ./flutter/pubspec.yaml.tmp ./flutter/pubspec.yaml
        rm -f ./flutter/pubspec.yaml.tmp
    fi
}

# macOS icon pipeline: app icon set, AppIcon.icns, menu-bar tray icons and the
# SVG the Flutter assets expect. Requires imagemagick + potrace.
apply_icon_macos() {
    ensure_icon || return 0
    local im
    im="$(magick_bin)" || { warn "imagemagick missing, skipping macOS icons"; return 0; }

    # Run launcher icons step FIRST so it does not overwrite custom assets later.
    (
        cd ./flutter || exit 0
        try flutter pub get
        try dart run flutter_launcher_icons || true
    )

    local iconset_dir="./flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    mkdir -p "$iconset_dir" ./res ./flutter/assets
    if [ -d "./macos/Runner/Assets.xcassets/AppIcon.appiconset" ]; then
        mkdir -p "./macos/Runner/Assets.xcassets/AppIcon.appiconset"
    fi

    log "generating macOS squircle icon assets"
    local macos_canvas="./res/icon_macos_squircle.png"
    try "$im" ./res/icon.png -resize 824x824 ./res/resized_824.png
    try "$im" -size 824x824 xc:none -fill white -draw "roundrectangle 0,0 824,824 180,180" ./res/mask_824.png
    try "$im" ./res/resized_824.png ./res/mask_824.png -compose DstIn -composite ./res/rounded_824.png
    try "$im" -size 1024x1024 xc:none ./res/rounded_824.png -gravity center -composite "$macos_canvas"
    rm -f ./res/resized_824.png ./res/mask_824.png ./res/rounded_824.png

    local icon_src="$macos_canvas"
    [ -f "$icon_src" ] || icon_src="./res/icon.png"

    local size
    for size in 16 32 64 128 256 512 1024; do
        try "$im" "$icon_src" -resize "${size}x${size}" "$iconset_dir/app_icon_${size}.png"
        if [ -d "./macos/Runner/Assets.xcassets/AppIcon.appiconset" ]; then
            try "$im" "$icon_src" -resize "${size}x${size}" "./macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png"
        fi
    done

    try "$im" "$icon_src" -resize 128x128 ./res/mac-icon.png
    try "$im" "$icon_src" -resize 22x22 -colorspace gray -alpha set -background none \
        -channel A -evaluate set 100% ./res/mac-tray-dark-x2.png
    try "$im" "$icon_src" -resize 22x22 -negate -colorspace gray -alpha set -background none \
        -channel A -evaluate set 100% ./res/mac-tray-light-x2.png

    # Vector asset used by the Flutter UI.
    if command -v potrace >/dev/null 2>&1; then
        try "$im" ./res/icon.png -flatten ./temp_icon.pbm
        try potrace --svg -o ./flutter/assets/icon.svg ./temp_icon.pbm
        rm -f ./temp_icon.pbm
    else
        warn "potrace missing, keeping the stock icon.svg"
    fi
    try cp ./res/mac-icon.png ./flutter/assets/icon.png

    cat > "$iconset_dir/Contents.json" <<JSON
{
  "images": [
    {"size":"16x16","idiom":"mac","filename":"app_icon_16.png","scale":"1x"},
    {"size":"16x16","idiom":"mac","filename":"app_icon_32.png","scale":"2x"},
    {"size":"32x32","idiom":"mac","filename":"app_icon_32.png","scale":"1x"},
    {"size":"32x32","idiom":"mac","filename":"app_icon_64.png","scale":"2x"},
    {"size":"128x128","idiom":"mac","filename":"app_icon_128.png","scale":"1x"},
    {"size":"128x128","idiom":"mac","filename":"app_icon_256.png","scale":"2x"},
    {"size":"256x256","idiom":"mac","filename":"app_icon_256.png","scale":"1x"},
    {"size":"256x256","idiom":"mac","filename":"app_icon_512.png","scale":"2x"},
    {"size":"512x512","idiom":"mac","filename":"app_icon_512.png","scale":"1x"},
    {"size":"512x512","idiom":"mac","filename":"app_icon_1024.png","scale":"2x"}
  ],
  "info": {"version": 1, "author": "xcode"}
}
JSON
    if [ -d "./macos/Runner/Assets.xcassets/AppIcon.appiconset" ]; then
        cp "$iconset_dir/Contents.json" "./macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json"
    fi

    # AppIcon.icns via iconutil (macOS only).
    if command -v iconutil >/dev/null 2>&1; then
        rm -rf ./iconset.iconset
        mkdir -p ./iconset.iconset
        try cp "$iconset_dir/app_icon_16.png"   ./iconset.iconset/icon_16x16.png
        try cp "$iconset_dir/app_icon_32.png"   ./iconset.iconset/icon_16x16@2x.png
        try cp "$iconset_dir/app_icon_32.png"   ./iconset.iconset/icon_32x32.png
        try cp "$iconset_dir/app_icon_64.png"   ./iconset.iconset/icon_32x32@2x.png
        try cp "$iconset_dir/app_icon_128.png"  ./iconset.iconset/icon_128x128.png
        try cp "$iconset_dir/app_icon_256.png"  ./iconset.iconset/icon_128x128@2x.png
        try cp "$iconset_dir/app_icon_256.png"  ./iconset.iconset/icon_256x256.png
        try cp "$iconset_dir/app_icon_512.png"  ./iconset.iconset/icon_256x256@2x.png
        try cp "$iconset_dir/app_icon_512.png"  ./iconset.iconset/icon_512x512.png
        try cp "$iconset_dir/app_icon_1024.png" ./iconset.iconset/icon_512x512@2x.png
        try iconutil -c icns ./iconset.iconset -o ./flutter/macos/Runner/AppIcon.icns
        try cp ./flutter/macos/Runner/AppIcon.icns ./res/AppIcon.icns 2>/dev/null || true
        if [ -d "./macos/Runner" ]; then
            try cp ./flutter/macos/Runner/AppIcon.icns ./macos/Runner/AppIcon.icns
        fi
        rm -rf ./iconset.iconset
    fi
}

