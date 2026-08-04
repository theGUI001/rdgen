import io
from pathlib import Path
from django.http import HttpResponse, JsonResponse, HttpResponseForbidden
from django.shortcuts import render, get_object_or_404
from django.core.files.base import ContentFile
import os
import secrets
import sys
import re
import requests
import base64
import json
import uuid
import pyzipper
from django.conf import settings as _settings
from django.db.models import Q
from .forms import GenerateForm
from .models import GithubRun, BuildBatch, BuildJob
from PIL import Image
from urllib.parse import quote


def generate_custom_client(params, full_url, engine='native'):
    """
    Core generation logic shared by web form and JSON API.

    Args:
        params: dict containing all configuration fields (keys match GenerateForm field names)
        full_url: the full URL of this service (protocol + host)
        engine: 'native' dispatches the classic per-platform generator-*.yml
                workflows; 'docker' dispatches docker-generator.yml, which runs
                the build inside a prebuilt Docker container.

    Returns:
        dict with 'success' key. On success: also includes 'uuid', 'filename', 'platform', 'log_url'.
        On failure: includes 'error' and optionally 'status_code'.
    """
    user_secret = params.get('sh_secret_field', '')
    selfhosted = (_settings.SH_SECRET == user_secret)
    platform = params.get('platform', 'windows')
    version = params.get('version', '1.4.9')
    delayFix = params.get('delayFix', True)
    xOffline = params.get('xOffline', False)
    hidecm = params.get('hidecm', False)
    removeNewVersionNotif = params.get('removeNewVersionNotif', False)
    server = params.get('serverIP', '')
    key = params.get('key', '')
    apiServer = params.get('apiServer', '')
    urlLink = params.get('urlLink', '')
    downloadLink = params.get('downloadLink', '')
    if not server:
        server = 'rs-ny.rustdesk.com' #default rustdesk server
    if not key:
        key = 'OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=' #default rustdesk key
    if not apiServer:
        apiServer = server+":21114"
    if not urlLink:
        urlLink = "https://rustdesk.com"
    if not downloadLink:
        downloadLink = "https://rustdesk.com/download"
    direction = params.get('direction', 'both')
    installation = params.get('installation', 'installationY')
    settings = params.get('settings', 'settingsY')
    appname = params.get('appname', '')
    if not appname:
        appname = "rustdesk"
    filename = params.get('exename', 'rustdesk')
    compname = params.get('compname', '')
    if not compname:
        compname = "Purslane Ltd"
    androidappid = params.get('androidappid', '')
    if not androidappid:
        androidappid = "com.carriez.flutter_hbb"
    compname = compname.replace("&","\\&")
    permPass = params.get('permanentPassword', '')
    theme = params.get('theme', 'system')
    themeDorO = params.get('themeDorO', 'default')
    passApproveMode = params.get('passApproveMode', 'password-click')
    denyLan = params.get('denyLan', False)
    enableDirectIP = params.get('enableDirectIP', False)
    autoClose = params.get('autoClose', False)
    permissionsDorO = params.get('permissionsDorO', 'default')
    permissionsType = params.get('permissionsType', 'custom')
    enableKeyboard = params.get('enableKeyboard', True)
    enableClipboard = params.get('enableClipboard', True)
    enableFileTransfer = params.get('enableFileTransfer', True)
    enableAudio = params.get('enableAudio', True)
    enableTCP = params.get('enableTCP', True)
    enableRemoteRestart = params.get('enableRemoteRestart', True)
    enableRecording = params.get('enableRecording', True)
    enableBlockingInput = params.get('enableBlockingInput', True)
    enableRemoteModi = params.get('enableRemoteModi', False)
    removeWallpaper = params.get('removeWallpaper', True)
    defaultManual = params.get('defaultManual', '')
    overrideManual = params.get('overrideManual', '')
    enablePrinter = params.get('enablePrinter', True)
    enableCamera = params.get('enableCamera', True)
    enableTerminal = params.get('enableTerminal', True)

    if all(char.isascii() for char in filename):
        filename = re.sub(r'[^\w\s-]', '_', filename).strip()
        filename = filename.replace(" ","_")
    else:
        filename = "rustdesk"
    if not all(char.isascii() for char in appname):
        appname = "rustdesk"
    myuuid = str(uuid.uuid4())

    try:
        iconfile = params.get('iconfile')
        if not iconfile:
            iconfile = params.get('iconbase64')
        iconlink_url, iconlink_uuid, iconlink_file = save_png(iconfile,myuuid,full_url,"icon.png")
    except:
        print("failed to get icon, using default")
        iconlink_url = "false"
        iconlink_uuid = "false"
        iconlink_file = "false"
    try:
        logofile = params.get('logofile')
        if not logofile:
            logofile = params.get('logobase64')
        logolink_url, logolink_uuid, logolink_file = save_png(logofile,myuuid,full_url,"logo.png")
    except:
        print("failed to get logo")
        logolink_url = "false"
        logolink_uuid = "false"
        logolink_file = "false"
    try:
        privacyfile = params.get('privacyfile')
        if not privacyfile:
            privacyfile = params.get('privacybase64')
        privacylink_url, privacylink_uuid, privacylink_file = save_png(privacyfile,myuuid,full_url,"privacy.png")
    except:
        print("failed to get logo")
        privacylink_url = "false"
        privacylink_uuid = "false"
        privacylink_file = "false"

    ###create the custom.txt json here and send in as inputs below
    decodedCustom = {}
    if direction != "Both":
        decodedCustom['conn-type'] = direction
    if installation == "installationN":
        decodedCustom['disable-installation'] = 'Y'
    if settings == "settingsN":
        decodedCustom['disable-settings'] = 'Y'
    if appname.upper != "rustdesk".upper and appname != "":
        decodedCustom['app-name'] = appname
    decodedCustom['override-settings'] = {}
    decodedCustom['default-settings'] = {}
    if permPass != "":
        decodedCustom['password'] = permPass
    if theme != "system":
        if themeDorO == "default":
            if platform == "windows-x86":
                decodedCustom['default-settings']['allow-darktheme'] = 'Y' if theme == "dark" else 'N'
            else:
                decodedCustom['default-settings']['theme'] = theme
        elif themeDorO == "override":
            if platform == "windows-x86":
                decodedCustom['override-settings']['allow-darktheme'] = 'Y' if theme == "dark" else 'N'
            else:
                decodedCustom['override-settings']['theme'] = theme
    decodedCustom['enable-lan-discovery'] = 'N' if denyLan else 'Y'
    #decodedCustom['direct-server'] = 'Y' if enableDirectIP else 'N'
    decodedCustom['allow-auto-disconnect'] = 'Y' if autoClose else 'N'
    if permissionsDorO == "default":
        decodedCustom['default-settings']['access-mode'] = permissionsType
        decodedCustom['default-settings']['enable-keyboard'] = 'Y' if enableKeyboard else 'N'
        decodedCustom['default-settings']['enable-clipboard'] = 'Y' if enableClipboard else 'N'
        decodedCustom['default-settings']['enable-file-transfer'] = 'Y' if enableFileTransfer else 'N'
        decodedCustom['default-settings']['enable-audio'] = 'Y' if enableAudio else 'N'
        decodedCustom['default-settings']['enable-tunnel'] = 'Y' if enableTCP else 'N'
        decodedCustom['default-settings']['enable-remote-restart'] = 'Y' if enableRemoteRestart else 'N'
        decodedCustom['default-settings']['enable-record-session'] = 'Y' if enableRecording else 'N'
        decodedCustom['default-settings']['enable-block-input'] = 'Y' if enableBlockingInput else 'N'
        decodedCustom['default-settings']['allow-remote-config-modification'] = 'Y' if enableRemoteModi else 'N'
        decodedCustom['default-settings']['direct-server'] = 'Y' if enableDirectIP else 'N'
        decodedCustom['default-settings']['verification-method'] = 'use-permanent-password' if hidecm else 'use-both-passwords'
        decodedCustom['default-settings']['approve-mode'] = passApproveMode
        decodedCustom['default-settings']['allow-hide-cm'] = 'Y' if hidecm else 'N'
        decodedCustom['default-settings']['allow-remove-wallpaper'] = 'Y' if removeWallpaper else 'N'
        decodedCustom['default-settings']['enable-remote-printer'] = 'Y' if enablePrinter else 'N'
        decodedCustom['default-settings']['enable-camera'] = 'Y' if enableCamera else 'N'
        decodedCustom['default-settings']['enable-terminal'] = 'Y' if enableTerminal else 'N'
    else:
        decodedCustom['override-settings']['access-mode'] = permissionsType
        decodedCustom['override-settings']['enable-keyboard'] = 'Y' if enableKeyboard else 'N'
        decodedCustom['override-settings']['enable-clipboard'] = 'Y' if enableClipboard else 'N'
        decodedCustom['override-settings']['enable-file-transfer'] = 'Y' if enableFileTransfer else 'N'
        decodedCustom['override-settings']['enable-audio'] = 'Y' if enableAudio else 'N'
        decodedCustom['override-settings']['enable-tunnel'] = 'Y' if enableTCP else 'N'
        decodedCustom['override-settings']['enable-remote-restart'] = 'Y' if enableRemoteRestart else 'N'
        decodedCustom['override-settings']['enable-record-session'] = 'Y' if enableRecording else 'N'
        decodedCustom['override-settings']['enable-block-input'] = 'Y' if enableBlockingInput else 'N'
        decodedCustom['override-settings']['allow-remote-config-modification'] = 'Y' if enableRemoteModi else 'N'
        decodedCustom['override-settings']['direct-server'] = 'Y' if enableDirectIP else 'N'
        decodedCustom['override-settings']['verification-method'] = 'use-permanent-password' if hidecm else 'use-both-passwords'
        decodedCustom['override-settings']['approve-mode'] = passApproveMode
        decodedCustom['override-settings']['allow-hide-cm'] = 'Y' if hidecm else 'N'
        decodedCustom['override-settings']['allow-remove-wallpaper'] = 'Y' if removeWallpaper else 'N'
        decodedCustom['override-settings']['enable-remote-printer'] = 'Y' if enablePrinter else 'N'
        decodedCustom['override-settings']['enable-camera'] = 'Y' if enableCamera else 'N'
        decodedCustom['override-settings']['enable-terminal'] = 'Y' if enableTerminal else 'N'

    if defaultManual:
        for line in defaultManual.splitlines():
            if '=' in line:
                k, value = line.split('=', 1)
                decodedCustom['default-settings'][k.strip()] = value.strip()

    if overrideManual:
        for line in overrideManual.splitlines():
            if '=' in line:
                k, value = line.split('=', 1)
                decodedCustom['override-settings'][k.strip()] = value.strip()
    
    decodedCustomJson = json.dumps(decodedCustom)

    string_bytes = decodedCustomJson.encode("ascii")
    base64_bytes = base64.b64encode(string_bytes)
    encodedCustom = base64_bytes.decode("ascii")

    # ---- Local engine: run the build on this machine, no GitHub -------------
    if engine == 'local' or getattr(_settings, 'BUILD_ENGINE', 'github') == 'local':
        local_config = {
            "platform": platform,
            "version": version,
            "server": server,
            "key": key,
            "apiServer": apiServer,
            "custom": encodedCustom,
            "appname": appname,
            "filename": filename,
            "compname": compname,
            "androidappid": androidappid,
            "urlLink": urlLink,
            "downloadLink": downloadLink,
            "delayFix": 'true' if delayFix else 'false',
            "xOffline": 'true' if xOffline else 'false',
            "hidecm": 'true' if hidecm else 'false',
            "removeNewVersionNotif": 'true' if removeNewVersionNotif else 'false',
            # Custom PNGs are served by this same app; the build fetches them if
            # it can reach us, and silently skips them otherwise.
            "iconlink_url": f"{full_url}" if iconlink_url != 'false' else 'false',
            "iconlink_uuid": iconlink_uuid,
            "iconlink_file": iconlink_file,
            "logolink_url": f"{full_url}" if logolink_url != 'false' else 'false',
            "logolink_uuid": logolink_uuid,
            "logolink_file": logolink_file,
            "privacylink_url": f"{full_url}" if privacylink_url != 'false' else 'false',
            "privacylink_uuid": privacylink_uuid,
            "privacylink_file": privacylink_file,
        }
        GithubRun.objects.update_or_create(
            uuid=myuuid,
            defaults={"status": "queued (local)", "local": True},
        )
        from .local_runner import start_local_build
        return start_local_build(myuuid, platform, local_config)

    ####from here run the github action, we need user, repo, access token.
    workflow_base = 'https://api.github.com/repos/'+_settings.GHUSER+'/'+_settings.REPONAME+'/actions/workflows/'
    if engine == 'docker':
        # Single container-based workflow handles every platform it can build.
        workflow_file = 'docker-generator.yml'
    elif platform == 'windows':
        workflow_file = 'sh-generator-windows.yml' if selfhosted else 'generator-windows.yml'
    elif platform == 'windows-x86':
        workflow_file = 'generator-windows-x86.yml'
    elif platform == 'linux':
        workflow_file = 'generator-linux.yml'
    elif platform == 'android':
        workflow_file = 'generator-android.yml'
    elif platform == 'macos':
        workflow_file = 'generator-macos.yml'
    else:
        workflow_file = 'sh-generator-windows.yml' if selfhosted else 'generator-windows.yml'
    url = workflow_base + workflow_file

    inputs_raw = {
        "server":server,
        "key":key,
        "apiServer":apiServer,
        "custom":encodedCustom,
        "uuid":myuuid,
        "iconlink_url":iconlink_url,
        "iconlink_uuid":iconlink_uuid,
        "iconlink_file":iconlink_file,
        "logolink_url":logolink_url,
        "logolink_uuid":logolink_uuid,
        "logolink_file":logolink_file,
        "privacylink_url":privacylink_url,
        "privacylink_uuid":privacylink_uuid,
        "privacylink_file":privacylink_file,
        "appname":appname,
        "genurl":_settings.GENURL,
        "urlLink":urlLink,
        "downloadLink":downloadLink,
        "delayFix": 'true' if delayFix else 'false',
        "rdgen":'true',
        "xOffline": 'true' if xOffline else 'false',
        "removeNewVersionNotif": 'true' if removeNewVersionNotif else 'false',
        "compname": compname,
        "androidappid":androidappid,
        "filename":filename
    }

    temp_json_path = f"data_{uuid.uuid4()}.json"
    zip_filename = f"secrets_{uuid.uuid4()}.zip"
    zip_path = "temp_zips/%s" % (zip_filename)
    Path("temp_zips").mkdir(parents=True, exist_ok=True)

    with open(temp_json_path, "w") as f:
        json.dump(inputs_raw, f)

    with pyzipper.AESZipFile(zip_path, 'w', compression=pyzipper.ZIP_LZMA, encryption=pyzipper.WZ_AES) as zf:
        zf.setpassword(_settings.ZIP_PASSWORD.encode())
        zf.write(temp_json_path, arcname="secrets.json")

    if os.path.exists(temp_json_path):
        os.remove(temp_json_path)

    zipJson = {}
    zipJson['url'] = full_url
    zipJson['file'] = zip_filename

    zip_url = json.dumps(zipJson)

    workflow_inputs = {
        "version": version,
        "zip_url": zip_url,
    }
    if engine == 'docker':
        # docker-generator.yml accepts a comma list of platforms; a single call
        # here targets one platform so per-platform status tracking still works.
        workflow_inputs["platforms"] = platform
        workflow_inputs["image_tag"] = getattr(_settings, 'BUILDER_IMAGE_TAG', 'latest')

    data = {
        "ref":_settings.GHBRANCH,
        "inputs": workflow_inputs,
        "return_run_details": True
    }
    headers = {
        'Accept':  'application/vnd.github+json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer '+_settings.GHBEARER,
        'X-GitHub-Api-Version': '2026-03-10'
    }
    new_github_run = GithubRun(
        uuid=myuuid,
        status="Starting generator...please wait"
    )
    try:
        response = requests.post(url, json=data, headers=headers)
        if response.status_code == 204 or response.status_code == 200:
            github_data = response.json()
            print(github_data)
            new_github_run.github_run_id = github_data.get('workflow_run_id')
            new_github_run.status = "in_progress"
            new_github_run.save()

            return {
                "success": True,
                "uuid": myuuid,
                "filename": filename,
                "platform": platform,
                "log_url": github_data.get('html_url')
            }
        else:
            return {
                "success": False,
                "error": "GitHub rejected the start request",
                "status_code": 500
            }
    except Exception as e:
        return {
            "success": False,
            "error": f"Connection error: {str(e)}",
            "status_code": 500
        }


def _get_run_status(uuid_val):
    """
    Core status-check logic shared by web form and JSON API.

    Args:
        uuid_val: the UUID string of the generation run

    Returns:
        dict with 'found', 'status', 'github_log_url', and optionally 'gh_run'.
        If not found, 'found' is False.
    """
    try:
        gh_run = GithubRun.objects.get(uuid=uuid_val)
    except GithubRun.DoesNotExist:
        return {"found": False}

    # Local builds are tracked entirely in the DB (updated by local_runner);
    # there is no GitHub run to poll or link to.
    if getattr(gh_run, 'local', False):
        return {
            "found": True,
            "status": gh_run.status,
            "github_log_url": f"/local_log?uuid={uuid_val}",
            "gh_run": gh_run,
        }

    github_log_url = f"https://github.com/{_settings.GHUSER}/{_settings.REPONAME}/actions/runs/{gh_run.github_run_id}"

    if gh_run.status not in ['success', 'failure', 'cancelled', 'timed_out', 'skipped']:
        headers = {
            "Authorization": f"Bearer {_settings.GHBEARER}",
            "Accept": "application/vnd.github+json"
        }
        api_url = f"https://api.github.com/repos/{_settings.GHUSER}/{_settings.REPONAME}/actions/runs/{gh_run.github_run_id}"
        
        try:
            gh_response = requests.get(api_url, headers=headers)
            if gh_response.status_code == 200:
                gh_data = gh_response.json()
                
                if gh_data['status'] == 'completed':
                    gh_run.status = gh_data['conclusion']
                    gh_run.save()
        except Exception as e:
            print(f"Error checking GitHub: {e}")

    return {
        "found": True,
        "status": gh_run.status,
        "github_log_url": github_log_url,
        "gh_run": gh_run
    }


def generator_view(request):
    if request.method == 'POST':
        form = GenerateForm(request.POST, request.FILES)
        if form.is_valid():
            params = form.cleaned_data
            full_url = f"{_settings.PROTOCOL}://{request.get_host()}" if _settings.GENURL else f"{_settings.PROTOCOL}://{request.get_host()}"
            result = generate_custom_client(params, full_url)
            if result['success']:
                return render(request, 'waiting.html', {
                    'filename': result['filename'],
                    'uuid': result['uuid'],
                    'status': "Starting generator...please wait",
                    'platform': result['platform'],
                    'log_url': result['log_url']
                })
            else:
                return JsonResponse({"error": result['error']}, status=result.get('status_code', 500))
    else:
        form = GenerateForm()
    #return render(request, 'maintenance.html')
    return render(request, 'generator.html', {'form': form})


# ---------------------------------------------------------------------------
# Batch builds: schedule the same configuration across several platforms at
# once, each running in its own Docker-based workflow run.
# ---------------------------------------------------------------------------

# Platforms the Docker engine can actually build. macOS/iOS need an Apple host.
DOCKER_PLATFORMS = ['linux', 'windows', 'android']


def _macos_available():
    """True when this host can build macOS itself (local engine on a Mac).

    Apple's toolchain never runs in a container, so macOS is only offered when
    the app runs in local mode on macOS, where scripts/macos/ builds natively.
    """
    return (
        sys.platform == 'darwin'
        and getattr(_settings, 'BUILD_ENGINE', 'github') == 'local'
        and 'macos' in getattr(_settings, 'LOCAL_BUILD_PLATFORMS', [])
    )


def _batch_platforms():
    """Platforms the batch scheduler may offer on this host."""
    platforms = list(DOCKER_PLATFORMS)
    if _macos_available():
        platforms.append('macos')
    return platforms


def batch_view(request):
    """Multi-platform scheduler UI. GET renders the form; POST fans out."""
    if request.method != 'POST':
        form = GenerateForm()
        return render(request, 'batch.html', {
            'form': form,
            'docker_platforms': _batch_platforms(),
            'macos_available': _macos_available(),
        })

    # A batch reuses GenerateForm for validation but ignores its single
    # `platform` field in favour of the `platforms` multi-select.
    form = GenerateForm(request.POST, request.FILES)
    if not form.is_valid():
        return render(request, 'batch.html', {
            'form': form,
            'docker_platforms': _batch_platforms(),
            'macos_available': _macos_available(),
            'errors': form.errors,
        })

    selected = request.POST.getlist('platforms')
    selected = [p for p in selected if p in _batch_platforms()]
    if not selected:
        return render(request, 'batch.html', {
            'form': form,
            'docker_platforms': _batch_platforms(),
            'macos_available': _macos_available(),
            'errors': {'platforms': ['Select at least one platform.']},
        })

    full_url = f"{_settings.PROTOCOL}://{request.get_host()}"
    base_params = dict(form.cleaned_data)
    label = request.POST.get('batch_label', '').strip()

    batch = BuildBatch(
        uuid=str(uuid.uuid4()),
        label=label,
        filename=base_params.get('exename', 'rustdesk'),
        engine='docker',
    )
    batch.save()

    for position, plat in enumerate(selected):
        params = dict(base_params)
        params['platform'] = plat
        job = BuildJob(
            batch=batch,
            platform=plat,
            uuid='',
            filename=base_params.get('exename', 'rustdesk'),
            position=position,
        )
        try:
            result = generate_custom_client(params, full_url, engine='docker')
        except Exception as e:  # never let one platform sink the whole batch
            result = {"success": False, "error": f"dispatch error: {e}"}

        if result.get('success'):
            job.uuid = result['uuid']
            job.status = 'in_progress'
            job.log_url = result.get('log_url', '') or ''
        else:
            job.uuid = str(uuid.uuid4())
            job.status = 'failure'
            job.error = str(result.get('error', 'unknown error'))[:500]
        job.save()

    return render(request, 'batch_status.html', {'batch': batch})


def _batch_payload(batch):
    """Collect the live status of every job in a batch for the dashboard/API."""
    jobs = []
    done = 0
    for job in batch.jobs.all():
        status = job.status
        log_url = job.log_url
        if job.status not in ['failure', 'success', 'cancelled', 'timed_out', 'skipped']:
            info = _get_run_status(job.uuid)
            if info['found']:
                status = info['status']
                log_url = info['github_log_url']
                if status != job.status:
                    job.status = status
                    job.log_url = log_url
                    job.save(update_fields=['status', 'log_url'])
        if status in ['failure', 'success', 'cancelled', 'timed_out', 'skipped']:
            done += 1
        jobs.append({
            'platform': job.platform,
            'uuid': job.uuid,
            'filename': job.filename,
            'status': status,
            'log_url': log_url,
            'error': job.error,
        })
    return {
        'uuid': batch.uuid,
        'label': batch.label,
        'filename': batch.filename,
        'jobs': jobs,
        'total': len(jobs),
        'completed': done,
        'all_done': done == len(jobs) and len(jobs) > 0,
    }


def batch_status(request):
    """HTML dashboard for a batch (batch=<uuid>)."""
    batch_uuid = request.GET.get('batch')
    batch = get_object_or_404(BuildBatch, uuid=batch_uuid)
    return render(request, 'batch_status.html', {'batch': batch})


def batch_status_json(request):
    """JSON status of a batch, polled by the dashboard and usable as an API."""
    batch_uuid = request.GET.get('batch')
    try:
        batch = BuildBatch.objects.get(uuid=batch_uuid)
    except BuildBatch.DoesNotExist:
        return JsonResponse({"error": "batch not found"}, status=404)
    return JsonResponse(_batch_payload(batch))


def check_for_file(request):
    filename = request.GET.get('filename')
    uuid = request.GET.get('uuid')
    platform = request.GET.get('platform')

    result = _get_run_status(uuid)
    if not result['found']:
        from django.http import Http404
        raise Http404("Run not found")

    gh_run = result['gh_run']
    github_log_url = result['github_log_url']

    if gh_run.status == "success":
        return render(request, 'generated.html', {
            'filename': filename, 
            'uuid': uuid, 
            'platform': platform
        })
        
    elif gh_run.status in ['failure', 'cancelled', 'timed_out', 'skipped', 'action_required']:
        return render(request, 'failure.html', {
            'log_url': github_log_url, 
            'filename': filename, 
            'uuid': uuid, 
            'platform': platform,
            'status': gh_run.status
        })
        
    else:
        return render(request, 'waiting.html', {
            'filename': filename, 
            'uuid': uuid, 
            'status': gh_run.status, 
            'platform': platform, 
            'log_url': github_log_url
        })

def download(request):
    filename = request.GET['filename']
    uuid = request.GET['uuid']
    # Guard against path traversal and only serve from exe/<uuid>/.
    base_dir = os.path.abspath(os.path.join('exe', uuid))
    file_path = os.path.abspath(os.path.join(base_dir, filename))
    if not file_path.startswith(base_dir + os.sep):
        return HttpResponseForbidden("Invalid filename")
    if not os.path.isfile(file_path):
        from django.http import Http404
        raise Http404("This artifact was not produced by the build")
    with open(file_path, 'rb') as file:
        content = file.read()
    response = HttpResponse(content, headers={
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': f'attachment; filename="{filename}"'
    })
    return response


def local_log(request):
    """Plain-text build log for a local build (build engine == 'local')."""
    uuid_val = request.GET.get('uuid', '')
    repo_root = getattr(_settings, 'RDGEN_REPO_ROOT', _settings.BASE_DIR)
    base_dir = os.path.abspath(os.path.join(str(repo_root), 'local_builds'))
    log_path = os.path.abspath(os.path.join(base_dir, uuid_val, 'build.log'))
    if not log_path.startswith(base_dir + os.sep) or not os.path.isfile(log_path):
        return HttpResponse("No local build log found for this run.",
                            content_type='text/plain', status=404)
    with open(log_path, 'r', errors='replace') as fh:
        content = fh.read()
    return HttpResponse(content, content_type='text/plain; charset=utf-8')

def get_png(request):
    filename = request.GET['filename']
    uuid = request.GET['uuid']
    #filename = filename+".exe"
    file_path = os.path.join('png',uuid,filename)
    with open(file_path, 'rb') as file:
        response = HttpResponse(file, headers={
            'Content-Type': 'application/vnd.microsoft.portable-executable',
            'Content-Disposition': f'attachment; filename="{filename}"'
        })

    return response

def create_github_run(myuuid):
    new_github_run = GithubRun(
        uuid=myuuid,
        status="Starting generator...please wait"
    )
    new_github_run.save()

def update_github_run(request):
    data = json.loads(request.body)
    myuuid = data.get('uuid')
    mystatus = data.get('status')
    GithubRun.objects.filter(Q(uuid=myuuid)).update(status=mystatus)
    return HttpResponse('')

def resize_and_encode_icon(imagefile):
    maxWidth = 200
    try:
        with io.BytesIO() as image_buffer:
            for chunk in imagefile.chunks():
                image_buffer.write(chunk)
            image_buffer.seek(0)

            img = Image.open(image_buffer)
            imgcopy = img.copy()
    except (IOError, OSError):
        raise ValueError("Uploaded file is not a valid image format.")

    # Check if resizing is necessary
    if img.size[0] <= maxWidth:
        with io.BytesIO() as image_buffer:
            imgcopy.save(image_buffer, format=imagefile.content_type.split('/')[1])
            image_buffer.seek(0)
            return_image = ContentFile(image_buffer.read(), name=imagefile.name)
        return base64.b64encode(return_image.read())

    # Calculate resized height based on aspect ratio
    wpercent = (maxWidth / float(img.size[0]))
    hsize = int((float(img.size[1]) * float(wpercent)))

    # Resize the image while maintaining aspect ratio using LANCZOS resampling
    imgcopy = imgcopy.resize((maxWidth, hsize), Image.Resampling.LANCZOS)

    with io.BytesIO() as resized_image_buffer:
        imgcopy.save(resized_image_buffer, format=imagefile.content_type.split('/')[1])
        resized_image_buffer.seek(0)

        resized_imagefile = ContentFile(resized_image_buffer.read(), name=imagefile.name)

    # Return the Base64 encoded representation of the resized image
    resized64 = base64.b64encode(resized_imagefile.read())
    #print(resized64)
    return resized64
 
#the following is used when accessed from an external source, like the rustdesk api server
def startgh(request):
    #print(request)
    data_ = json.loads(request.body)
    ####from here run the github action, we need user, repo, access token.
    url = 'https://api.github.com/repos/'+_settings.GHUSER+'/'+_settings.REPONAME+'/actions/workflows/generator-'+data_.get('platform')+'.yml/dispatches'  
    data = {
        "ref": _settings.GHBRANCH,
        "inputs":{
            "server":data_.get('server'),
            "key":data_.get('key'),
            "apiServer":data_.get('apiServer'),
            "custom":data_.get('custom'),
            "uuid":data_.get('uuid'),
            "iconlink":data_.get('iconlink'),
            "logolink":data_.get('logolink'),
            "appname":data_.get('appname'),
            "extras":data_.get('extras'),
            "filename":data_.get('filename')
        }
    } 
    headers = {
        'Accept':  'application/vnd.github+json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer '+_settings.GHBEARER,
        'X-GitHub-Api-Version': '2026-03-10'
    }
    response = requests.post(url, json=data, headers=headers)
    print(response)
    return HttpResponse(status=204)

def save_png(file, uuid, domain, name):
    file_save_path = "png/%s/%s" % (uuid, name)
    Path("png/%s" % uuid).mkdir(parents=True, exist_ok=True)

    if isinstance(file, str):  # Check if it's a base64 string
        try:
            header, encoded = file.split(';base64,')
            decoded_img = base64.b64decode(encoded)
            file = ContentFile(decoded_img, name=name) # Create a file-like object
        except ValueError:
            print("Invalid base64 data")
            return None  # Or handle the error as you see fit
        except Exception as e:  # Catch general exceptions during decoding
            print(f"Error decoding base64: {e}")
            return None
        
    with open(file_save_path, "wb+") as f:
        for chunk in file.chunks():
            f.write(chunk)
    # imageJson = {}
    # imageJson['url'] = domain
    # imageJson['uuid'] = uuid
    # imageJson['file'] = name
    #return "%s/%s" % (domain, file_save_path)
    return domain, uuid, name

def save_custom_client(request):
    file = request.FILES['file']
    myuuid = request.POST.get('uuid')
    file_save_path = "exe/%s/%s" % (myuuid, file.name)
    Path("exe/%s" % myuuid).mkdir(parents=True, exist_ok=True)
    with open(file_save_path, "wb+") as f:
        for chunk in file.chunks():
            f.write(chunk)

    return HttpResponse("File saved successfully!")

def cleanup_secrets(request):
    # Pass the UUID as a query param or in JSON body
    data = json.loads(request.body)
    my_uuid = data.get('uuid')
    
    if not my_uuid:
        return HttpResponse("Missing UUID", status=400)

    # 1. Find the files in your temp directory matching the UUID
    temp_dir = os.path.join('temp_zips')
    
    # We look for any file starting with 'secrets_' and containing the uuid
    for filename in os.listdir(temp_dir):
        if my_uuid in filename and filename.endswith('.zip'):
            file_path = os.path.join(temp_dir, filename)
            try:
                os.remove(file_path)
                print(f"Successfully deleted {file_path}")
            except OSError as e:
                print(f"Error deleting file: {e}")

    return HttpResponse("Cleanup successful", status=200)

def get_zip(request):
    filename = request.GET['filename']
    base_dir = os.path.abspath('temp_zips')
    file_path = os.path.abspath(os.path.join(base_dir, filename))
    if not file_path.startswith(base_dir + os.sep):
        return HttpResponseForbidden("Invalid filename")
    with open(file_path, 'rb') as file:
        response = HttpResponse(file, headers={
            'Content-Type': 'application/vnd.microsoft.portable-executable',
            'Content-Disposition': f'attachment; filename="{filename}"'
        })

    return response
