#!/usr/bin/env python3
"""
Extracts custom icon and logo files from build.json / hdesk149.json and generates
all required icon formats (.ico, .png sets) for Windows and macOS builds.
"""
import sys
import os
import json
import base64
import struct
import urllib.request

# Try importing PIL, or auto-install, or use fallback
try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    try:
        import subprocess
        subprocess.run([sys.executable, "-m", "pip", "install", "Pillow"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        from PIL import Image
        HAS_PIL = True
    except Exception:
        HAS_PIL = False

def create_png_ico(png_bytes):
    """Creates a valid 256x256 ICO file wrapping raw PNG bytes (supported on Windows Vista+)."""
    header = struct.pack('<HHH', 0, 1, 1)  # Reserved, Type 1 (ICO), 1 image
    entry = struct.pack('<BBBBHHII',
        0,                 # Width (0 = 256px)
        0,                 # Height (0 = 256px)
        0,                 # Palette
        0,                 # Reserved
        1,                 # Color planes
        32,                # Bits per pixel
        len(png_bytes),    # Image size in bytes
        22                 # Offset to image data (6 header + 16 entry = 22)
    )
    return header + entry + png_bytes

def process_icons(config_path, rustdesk_dir):
    global HAS_PIL
    if not os.path.exists(config_path):
        print(f"[process_icons] Config file not found: {config_path}")
        return

    with open(config_path, 'r', encoding='utf-8') as f:
        cfg = json.load(f)

    res_dir = os.path.join(rustdesk_dir, 'res')
    flutter_assets_dir = os.path.join(rustdesk_dir, 'flutter', 'assets')
    os.makedirs(res_dir, exist_ok=True)
    os.makedirs(flutter_assets_dir, exist_ok=True)

    # --- 1. Extract icon PNG ---
    icon_png_path = os.path.join(res_dir, 'icon.png')
    icon_found = False
    raw_icon_bytes = None

    for key in ['iconfile', 'iconbase64']:
        val = cfg.get(key, '')
        if val and isinstance(val, str) and len(val) > 20:
            if ';base64,' in val:
                val = val.split(';base64,')[1]
            try:
                raw_icon_bytes = base64.b64decode(val)
                with open(icon_png_path, 'wb') as f_out:
                    f_out.write(raw_icon_bytes)
                icon_found = True
                print(f"[process_icons] Successfully decoded icon from {key}")
                break
            except Exception as e:
                print(f"[process_icons] Error decoding base64 from {key}: {e}")

    if not icon_found and cfg.get('iconpath') and os.path.isfile(cfg['iconpath']):
        try:
            with open(cfg['iconpath'], 'rb') as f_in:
                raw_icon_bytes = f_in.read()
            with open(icon_png_path, 'wb') as f_out:
                f_out.write(raw_icon_bytes)
            icon_found = True
            print(f"[process_icons] Copied icon file from {cfg['iconpath']}")
        except Exception as e:
            print(f"[process_icons] Error reading iconpath: {e}")

    if not icon_found and cfg.get('iconlink_url') and cfg['iconlink_url'] != 'false':
        url = cfg['iconlink_url']
        if 'get_png' not in url and cfg.get('iconlink_file') and cfg.get('iconlink_uuid'):
            url = f"{url}/get_png?filename={cfg.get('iconlink_file')}&uuid={cfg.get('iconlink_uuid')}"
        try:
            raw_icon_bytes = urllib.request.urlopen(url).read()
            with open(icon_png_path, 'wb') as f_out:
                f_out.write(raw_icon_bytes)
            icon_found = True
            print(f"[process_icons] Downloaded icon from {url}")
        except Exception as e:
            print(f"[process_icons] Error downloading icon from {url}: {e}")

    # Generate multi-format icon assets if icon.png is available
    if os.path.isfile(icon_png_path):
        if raw_icon_bytes is None:
            with open(icon_png_path, 'rb') as f_in:
                raw_icon_bytes = f_in.read()

        ico_path = os.path.join(res_dir, 'icon.ico')
        tray_ico_path = os.path.join(res_dir, 'tray-icon.ico')
        flutter_win_res = os.path.join(rustdesk_dir, 'flutter', 'windows', 'runner', 'resources')

        if HAS_PIL:
            try:
                img = Image.open(icon_png_path).convert('RGBA')
                img.save(ico_path, format='ICO', sizes=[(16,16), (32,32), (48,48), (64,64), (128,128), (256,256)])
                img.save(tray_ico_path, format='ICO', sizes=[(16,16), (32,32), (48,48), (64,64)])
                
                if os.path.isdir(flutter_win_res):
                    img.save(os.path.join(flutter_win_res, 'app_icon.ico'), format='ICO', sizes=[(16,16), (32,32), (48,48), (64,64), (128,128), (256,256)])

                img.resize((32, 32), Image.Resampling.LANCZOS).save(os.path.join(res_dir, '32x32.png'))
                img.resize((64, 64), Image.Resampling.LANCZOS).save(os.path.join(res_dir, '64x64.png'))
                img.resize((128, 128), Image.Resampling.LANCZOS).save(os.path.join(res_dir, '128x128.png'))
                img.resize((256, 256), Image.Resampling.LANCZOS).save(os.path.join(res_dir, '128x128@2x.png'))
                img.resize((128, 128), Image.Resampling.LANCZOS).save(os.path.join(flutter_assets_dir, 'icon.png'))
                img.resize((128, 128), Image.Resampling.LANCZOS).save(os.path.join(res_dir, 'mac-icon.png'))

                mac_iconset = os.path.join(rustdesk_dir, 'flutter', 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
                if os.path.isdir(mac_iconset):
                    for size in [16, 32, 64, 128, 256, 512, 1024]:
                        img.resize((size, size), Image.Resampling.LANCZOS).save(os.path.join(mac_iconset, f'app_icon_{size}.png'))
                    print("[process_icons] Updated macOS AppIcon.appiconset PNGs using PIL")

                print("[process_icons] Generated multi-size icon assets using PIL.")
            except Exception as e:
                print(f"[process_icons] Error generating icons with PIL: {e}")
                HAS_PIL = False

        if not HAS_PIL:
            print("[process_icons] PIL not available, using raw PNG ICO header fallback")
            ico_bytes = create_png_ico(raw_icon_bytes)
            with open(ico_path, 'wb') as f_out:
                f_out.write(ico_bytes)
            with open(tray_ico_path, 'wb') as f_out:
                f_out.write(ico_bytes)
            if os.path.isdir(flutter_win_res):
                with open(os.path.join(flutter_win_res, 'app_icon.ico'), 'wb') as f_out:
                    f_out.write(ico_bytes)
            import shutil
            shutil.copy(icon_png_path, os.path.join(res_dir, '32x32.png'))
            shutil.copy(icon_png_path, os.path.join(res_dir, '64x64.png'))
            shutil.copy(icon_png_path, os.path.join(res_dir, '128x128.png'))
            shutil.copy(icon_png_path, os.path.join(res_dir, '128x128@2x.png'))
            shutil.copy(icon_png_path, os.path.join(flutter_assets_dir, 'icon.png'))

    # --- 2. Extract logo PNG ---
    logo_png_path = os.path.join(res_dir, 'logo.png')
    logo_found = False
    for key in ['logofile', 'logobase64']:
        val = cfg.get(key, '')
        if val and isinstance(val, str) and len(val) > 20:
            if ';base64,' in val:
                val = val.split(';base64,')[1]
            try:
                data = base64.b64decode(val)
                with open(logo_png_path, 'wb') as f_out:
                    f_out.write(data)
                logo_found = True
                print(f"[process_icons] Successfully decoded logo from {key}")
                break
            except Exception as e:
                print(f"[process_icons] Error decoding base64 from {key}: {e}")

    if logo_found and os.path.isfile(logo_png_path):
        import shutil
        shutil.copy(logo_png_path, os.path.join(flutter_assets_dir, 'logo.png'))
        print("[process_icons] Updated flutter logo.png")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python process_icons.py <config.json> <rustdesk_dir>")
        sys.exit(1)
    process_icons(sys.argv[1], sys.argv[2])
