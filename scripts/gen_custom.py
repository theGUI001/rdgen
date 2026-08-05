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

def apply_company_name(compname, rustdesk_dir):
    if not compname or compname == "Purslane Ltd":
        return
    files = [
        os.path.join(rustdesk_dir, 'flutter', 'lib', 'desktop', 'pages', 'desktop_setting_page.dart'),
        os.path.join(rustdesk_dir, 'Cargo.toml'),
        os.path.join(rustdesk_dir, 'libs', 'portable', 'Cargo.toml'),
        os.path.join(rustdesk_dir, 'src', 'ui', 'index.tis'),
        os.path.join(rustdesk_dir, 'src', 'main.rs'),
    ]
    for fpath in files:
        if os.path.isfile(fpath):
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    content = f.read()
                content = content.replace("Purslane Tech Pte. Ltd.", compname)
                content = content.replace("Purslane Ltd.", compname)
                content = content.replace("Purslane Ltd", compname)
                with open(fpath, 'w', encoding='utf-8') as f:
                    f.write(content)
                print(f"[gen_custom] Replaced company name in {fpath}")
            except Exception as e:
                print(f"[gen_custom] Error updating {fpath}: {e}")

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
        compname = cfg.get('compname', '')
        if compname:
            apply_company_name(compname, rustdesk_dir)

    custom = cfg.get('custom', '')
    if not custom:
        custom = build_custom_base64(cfg)
    print(custom)

if __name__ == '__main__':
    main()
