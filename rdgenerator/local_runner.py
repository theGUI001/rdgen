"""Run custom-client builds on this machine instead of on GitHub Actions.

When ``settings.BUILD_ENGINE == 'local'`` the web form and batch scheduler call
:func:`start_local_build` instead of dispatching a GitHub workflow. The build
runs in a background thread via ``scripts/rdbuild.sh`` (Docker), and its status
is tracked in the same ``GithubRun`` row the existing waiting/dashboard pages
poll — so the rest of the app is unchanged.

Artifacts produced in ``<repo>/local_builds/<uuid>/output/<platform>/`` are
copied into ``<repo>/exe/<uuid>/`` where the ``/download`` view serves them,
matching the filenames the templates link to (``<filename>-x86_64.deb`` etc).
"""
import json
import os
import shutil
import subprocess
import threading
from pathlib import Path

from django.conf import settings


def _repo_root():
    return Path(getattr(settings, 'RDGEN_REPO_ROOT', settings.BASE_DIR))


def _set_status(uuid_val, status):
    # Imported lazily to avoid a circular import at module load.
    from .models import GithubRun
    GithubRun.objects.filter(uuid=uuid_val).update(status=status)


def _copy_artifacts(uuid_val, platform, out_dir):
    """Copy built files into exe/<uuid>/ so /download can serve them."""
    dest = _repo_root() / 'exe' / uuid_val
    dest.mkdir(parents=True, exist_ok=True)
    src = Path(out_dir) / platform
    copied = 0
    if src.is_dir():
        for item in src.iterdir():
            if item.is_file():
                shutil.copy(str(item), str(dest / item.name))
                copied += 1
    return copied


def _run(uuid_val, platform, work_dir, config_path):
    repo_root = _repo_root()
    log_path = Path(work_dir) / 'build.log'
    out_dir = Path(work_dir) / 'output'

    _set_status(uuid_val, 'building (local)')

    is_windows_native = (
        platform == 'windows'
        and getattr(settings, 'LOCAL_WINDOWS_NATIVE', os.name == 'nt')
    )
    if is_windows_native:
        # Native Windows build (e.g. inside a Hyper-V VM): no Docker.
        script = repo_root / 'scripts' / 'windows' / 'build-windows-native.ps1'
        cmd = [
            'powershell', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', str(script),
            '-Config', str(config_path),
            '-Output', str(out_dir / 'windows'),
        ]
    else:
        script = repo_root / 'scripts' / 'rdbuild.sh'
        cmd = [
            'bash', str(script),
            '--config', str(config_path),
            '--platforms', platform,
            '--output', str(out_dir),
        ]

    returncode = 1
    try:
        with open(log_path, 'w') as logfile:
            proc = subprocess.run(
                cmd, cwd=str(repo_root),
                stdout=logfile, stderr=subprocess.STDOUT,
            )
            returncode = proc.returncode
    except Exception as e:  # launcher-level failure (missing bash/powershell, …)
        try:
            with open(log_path, 'a') as logfile:
                logfile.write(f"\n[local_runner] launcher error: {e}\n")
        except OSError:
            pass
        returncode = 1

    if returncode == 0:
        copied = _copy_artifacts(uuid_val, platform, out_dir)
        _set_status(uuid_val, 'success' if copied else 'failure')
    else:
        _set_status(uuid_val, 'failure')


def start_local_build(uuid_val, platform, config):
    """Kick off a local build in a background thread.

    Args:
        uuid_val: the run uuid (also the GithubRun uuid).
        platform: 'linux' | 'android' | 'windows'.
        config: dict of build.json values (see scripts/config.example.json).

    Returns:
        dict with 'success'. On success also 'uuid', 'filename', 'platform',
        'log_url' (a local status URL). On failure, 'error'.
    """
    allowed = getattr(settings, 'LOCAL_BUILD_PLATFORMS', ['linux', 'android', 'windows'])
    allowed = [p.strip() for p in allowed]
    if platform not in allowed:
        return {
            "success": False,
            "error": (
                f"Platform '{platform}' is not enabled for local builds "
                f"(LOCAL_BUILD_PLATFORMS={allowed}). macOS/iOS need an Apple host."
            ),
            "status_code": 400,
        }

    work_dir = _repo_root() / 'local_builds' / uuid_val
    work_dir.mkdir(parents=True, exist_ok=True)

    cfg = dict(config)
    cfg['platform'] = platform
    cfg['uuid'] = uuid_val
    # Django manages status + artifacts locally; the build must not try to POST
    # them back over the network.
    cfg.pop('upload_url', None)
    cfg.pop('status_url', None)

    config_path = work_dir / 'build.json'
    config_path.write_text(json.dumps(cfg, indent=2))

    thread = threading.Thread(
        target=_run,
        args=(uuid_val, platform, str(work_dir), str(config_path)),
        daemon=True,
    )
    thread.start()

    return {
        "success": True,
        "uuid": uuid_val,
        "filename": cfg.get('filename', 'rustdesk'),
        "platform": platform,
        "log_url": f"/local_log?uuid={uuid_val}",
    }
