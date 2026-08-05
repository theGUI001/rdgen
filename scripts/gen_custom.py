import sys
import os
import json
import base64

def build_custom_base64(params):
    direction = params.get('direction', 'both')
    installation = params.get('installation', 'installationY')
    settings = params.get('settings', 'settingsY')
    appname = params.get('appname', 'rustdesk')
    permPass = params.get('permanentPassword', '')
    theme = params.get('theme', 'system')
    themeDorO = params.get('themeDorO', 'default')
    passApproveMode = params.get('passApproveMode', 'password-click')
    denyLan = params.get('denyLan', False)
    enableDirectIP = params.get('enableDirectIP', False)
    if isinstance(enableDirectIP, str):
        enableDirectIP = (enableDirectIP.lower() in ('true', 'on', '1', 'yes'))
    autoClose = params.get('autoClose', False)
    if isinstance(autoClose, str):
        autoClose = (autoClose.lower() in ('true', 'on', '1', 'yes'))
    permissionsDorO = params.get('permissionsDorO', 'default')
    permissionsType = params.get('permissionsType', 'custom')

    def parse_bool(v, default=True):
        if isinstance(v, bool): return v
        if isinstance(v, str): return v.lower() in ('true', 'on', '1', 'yes')
        return default

    enableKeyboard = parse_bool(params.get('enableKeyboard'), True)
    enableClipboard = parse_bool(params.get('enableClipboard'), True)
    enableFileTransfer = parse_bool(params.get('enableFileTransfer'), True)
    enableAudio = parse_bool(params.get('enableAudio'), True)
    enableTCP = parse_bool(params.get('enableTCP'), True)
    enableRemoteRestart = parse_bool(params.get('enableRemoteRestart'), True)
    enableRecording = parse_bool(params.get('enableRecording'), True)
    enableBlockingInput = parse_bool(params.get('enableBlockingInput'), True)
    enableRemoteModi = parse_bool(params.get('enableRemoteModi'), False)
    removeWallpaper = parse_bool(params.get('removeWallpaper'), True)
    enablePrinter = parse_bool(params.get('enablePrinter'), True)
    enableCamera = parse_bool(params.get('enableCamera'), True)
    enableTerminal = parse_bool(params.get('enableTerminal'), True)
    hidecm = parse_bool(params.get('hidecm'), False)

    decodedCustom = {}
    if direction.lower() != "both":
        decodedCustom['conn-type'] = direction
    if installation == "installationN":
        decodedCustom['disable-installation'] = 'Y'
    if settings == "settingsN":
        decodedCustom['disable-settings'] = 'Y'
    if appname and appname.upper() != "RUSTDESK":
        decodedCustom['app-name'] = appname
    decodedCustom['override-settings'] = {}
    decodedCustom['default-settings'] = {}
    if permPass:
        decodedCustom['password'] = permPass

    if theme != "system":
        theme_target = decodedCustom['override-settings'] if themeDorO == "override" else decodedCustom['default-settings']
        theme_target['theme'] = theme

    decodedCustom['enable-lan-discovery'] = 'N' if denyLan else 'Y'
    decodedCustom['allow-auto-disconnect'] = 'Y' if autoClose else 'N'

    target_dict = decodedCustom['override-settings'] if permissionsDorO == "override" else decodedCustom['default-settings']

    target_dict['access-mode'] = permissionsType
    target_dict['enable-keyboard'] = 'Y' if enableKeyboard else 'N'
    target_dict['enable-clipboard'] = 'Y' if enableClipboard else 'N'
    target_dict['enable-file-transfer'] = 'Y' if enableFileTransfer else 'N'
    target_dict['enable-audio'] = 'Y' if enableAudio else 'N'
    target_dict['enable-tunnel'] = 'Y' if enableTCP else 'N'
    target_dict['enable-remote-restart'] = 'Y' if enableRemoteRestart else 'N'
    target_dict['enable-record-session'] = 'Y' if enableRecording else 'N'
    target_dict['enable-block-input'] = 'Y' if enableBlockingInput else 'N'
    target_dict['allow-remote-config-modification'] = 'Y' if enableRemoteModi else 'N'
    target_dict['direct-server'] = 'Y' if enableDirectIP else 'N'
    target_dict['verification-method'] = 'use-permanent-password' if hidecm else 'use-both-passwords'
    target_dict['approve-mode'] = passApproveMode
    target_dict['allow-hide-cm'] = 'Y' if hidecm else 'N'
    target_dict['allow-remove-wallpaper'] = 'Y' if removeWallpaper else 'N'
    target_dict['enable-remote-printer'] = 'Y' if enablePrinter else 'N'
    target_dict['enable-camera'] = 'Y' if enableCamera else 'N'
    target_dict['enable-terminal'] = 'Y' if enableTerminal else 'N'

    decodedCustomJson = json.dumps(decodedCustom)
    return base64.b64encode(decodedCustomJson.encode('utf-8')).decode('ascii')

def replace_in_file(filepath, replacements):
    if not os.path.isfile(filepath):
        return
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        orig = content
        for old, new in replacements:
            content = content.replace(old, new)
        if content != orig:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(content)
            print(f"[gen_custom] Updated {filepath}")
    except Exception as e:
        print(f"[gen_custom] Error updating {filepath}: {e}")

def apply_all_customisations(cfg, rustdesk_dir):
    server = cfg.get('server') or cfg.get('serverIP') or 'rs-ny.rustdesk.com'
    key = cfg.get('key') or 'OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw='
    apiServer = cfg.get('apiServer') or f"{server}:21114"
    appname = cfg.get('appname') or 'rustdesk'
    compname = cfg.get('compname') or 'Purslane Ltd'

    # 1. Server, Key, and APP_NAME in libs/hbb_common/src/config.rs
    hbb_config = os.path.join(rustdesk_dir, 'libs', 'hbb_common', 'src', 'config.rs')
    repls = [
        ("rs-ny.rustdesk.com", server),
        ("OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=", key),
    ]
    if appname and appname.lower() != "rustdesk":
        repls.append(('RwLock::new("RustDesk".to_owned())', f'RwLock::new("{appname}".to_owned())'))
    replace_in_file(hbb_config, repls)

    # 2. API Server in src/common.rs
    src_common = os.path.join(rustdesk_dir, 'src', 'common.rs')
    replace_in_file(src_common, [("https://admin.rustdesk.com", apiServer)])

    # 3. App Name / Whitelabel across Cargo.toml, portable main.rs, lang files
    if appname and appname.lower() != "rustdesk":
        app_cargo = [
            ('description = "RustDesk Remote Desktop"', f'description = "{appname}"'),
            ('ProductName = "RustDesk"', f'ProductName = "{appname}"'),
            ('FileDescription = "RustDesk Remote Desktop"', f'FileDescription = "{appname}"'),
            ('OriginalFilename = "rustdesk.exe"', f'OriginalFilename = "{appname}.exe"'),
        ]
        replace_in_file(os.path.join(rustdesk_dir, 'Cargo.toml'), app_cargo)
        replace_in_file(os.path.join(rustdesk_dir, 'libs', 'portable', 'Cargo.toml'), app_cargo)

        portable_main = os.path.join(rustdesk_dir, 'libs', 'portable', 'src', 'main.rs')
        replace_in_file(portable_main, [
            ('const APP_PREFIX: &str = "rustdesk";', f'const APP_PREFIX: &str = "{appname.lower()}";'),
            ('const APP_PREFIX: &str = "RustDesk";', f'const APP_PREFIX: &str = "{appname}";'),
        ])

        lang_dir = os.path.join(rustdesk_dir, 'src', 'lang')
        if os.path.isdir(lang_dir):
            for fname in os.listdir(lang_dir):
                if fname.endswith('.rs'):
                    replace_in_file(os.path.join(lang_dir, fname), [("RustDesk", appname)])

    # 4. Company Name (compname)
    if compname and compname != "Purslane Ltd":
        comp_files = [
            os.path.join(rustdesk_dir, 'flutter', 'lib', 'desktop', 'pages', 'desktop_setting_page.dart'),
            os.path.join(rustdesk_dir, 'Cargo.toml'),
            os.path.join(rustdesk_dir, 'libs', 'portable', 'Cargo.toml'),
            os.path.join(rustdesk_dir, 'src', 'ui', 'index.tis'),
            os.path.join(rustdesk_dir, 'src', 'main.rs'),
        ]
        for fpath in comp_files:
            replace_in_file(fpath, [
                ("Purslane Tech Pte. Ltd.", compname),
                ("Purslane Ltd.", compname),
                ("Purslane Ltd", compname),
            ])

    # 5. Connection delay fix if delayFix is enabled
    delay_fix = cfg.get('delayFix', True)
    if isinstance(delay_fix, str):
        delay_fix = (delay_fix.lower() in ('true', 'on', '1', 'yes'))
    if delay_fix:
        client_rs = os.path.join(rustdesk_dir, 'src', 'client.rs')
        replace_in_file(client_rs, [("!key.is_empty()", "false")])

def main():
    if len(sys.argv) < 2:
        return
    config_path = sys.argv[1]
    if not os.path.exists(config_path):
        return
    with open(config_path, 'r', encoding='utf-8') as f:
        cfg = json.load(f)

    if len(sys.argv) >= 3:
        rustdesk_dir = sys.argv[2]
        apply_all_customisations(cfg, rustdesk_dir)

    custom = cfg.get('custom', '')
    if not custom:
        custom = build_custom_base64(cfg)
    print(custom)

if __name__ == '__main__':
    main()
