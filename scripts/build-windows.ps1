# Entry point for the Windows builder image. Produces a portable .exe and .msi.
#
# Runs inside the windows-builder container (Windows container on a Windows
# host). Configuration comes from C:\work\build.json, same schema as the other
# platforms.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Work    = if ($env:RD_WORK) { $env:RD_WORK } else { 'C:\work' }
$Src     = Join-Path $Work 'rustdesk'
$Out     = Join-Path $Work 'output'
$Config  = if ($env:RD_CONFIG) { $env:RD_CONFIG } else { Join-Path $Work 'build.json' }
$Patches = 'C:\patches'

function Log($m)  { Write-Host "[rdgen] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[rdgen] $m" -ForegroundColor Yellow }
function Try-Step([scriptblock]$b) {
    try { & $b } catch { Warn "step failed (ignored): $($_.Exception.Message)" }
}

if (-not (Test-Path $Config)) { throw "config not found: $Config" }
$cfg = Get-Content $Config -Raw | ConvertFrom-Json

function Cfg($name, $default) {
    if ($cfg.PSObject.Properties.Name -contains $name -and $null -ne $cfg.$name -and "$($cfg.$name)" -ne '') {
        return $cfg.$name
    }
    return $default
}

$version      = Cfg 'version' 'master'
$server       = Cfg 'server' 'rs-ny.rustdesk.com'
$key          = Cfg 'key' 'OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw='
$apiServer    = Cfg 'apiServer' "$server`:21114"
$appname      = Cfg 'appname' 'rustdesk'
$filename     = Cfg 'filename' 'rustdesk'
$compname     = Cfg 'compname' 'Purslane Ltd'
$urlLink      = Cfg 'urlLink' 'https://rustdesk.com'
$downloadLink = Cfg 'downloadLink' 'https://rustdesk.com/download'
$custom       = Cfg 'custom' ''
$uuid         = Cfg 'uuid' 'local'
$delayFix     = "$(Cfg 'delayFix' 'true')" -eq 'true'
$removeNotif  = "$(Cfg 'removeNewVersionNotif' 'false')" -eq 'true'
$uploadUrl    = Cfg 'upload_url' ''
$statusUrl    = Cfg 'status_url' ''
$token        = Cfg 'token' ''

function Report($status) {
    Log "status: $status"
    if (-not $statusUrl) { return }
    Try-Step {
        $body = @{ uuid = $uuid; status = $status } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri $statusUrl -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    }
}

function Upload($file) {
    if (-not (Test-Path $file)) { Warn "nothing to upload at $file"; return }
    if (-not $uploadUrl) { Log "built $(Split-Path $file -Leaf) (no upload_url set)"; return }
    for ($i = 1; $i -le 3; $i++) {
        try {
            $form = @{ file = Get-Item $file; uuid = $uuid }
            $headers = @{ Authorization = "Bearer $token" }
            Invoke-RestMethod -Uri $uploadUrl -Method Post -Form $form -Headers $headers -TimeoutSec 900 | Out-Null
            Log "uploaded $(Split-Path $file -Leaf)"; return
        } catch { Warn "upload failed (attempt $i/3): $($_.Exception.Message)"; Start-Sleep ($i * 10) }
    }
}

# --- checkout ---------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Out | Out-Null
git config --global --add safe.directory '*' | Out-Null
Report 'Preparing Windows build environment'

if (-not (Test-Path (Join-Path $Src '.git'))) {
    Log "cloning rustdesk@$version"
    if ($version -eq 'master') {
        git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/rustdesk/rustdesk $Src
    } else {
        git clone --depth 1 --branch $version --recurse-submodules --shallow-submodules https://github.com/rustdesk/rustdesk $Src
    }
}
Set-Location $Src

# --- customise (bash does the heavy lifting; git for windows ships it) -------
Report 'Applying customisations'
$env:platform='windows'; $env:server=$server; $env:key=$key; $env:apiServer=$apiServer
$env:appname=$appname; $env:filename=$filename; $env:compname=$compname
$env:urlLink=$urlLink; $env:downloadLink=$downloadLink; $env:custom=$custom
$env:delayFix = if ($delayFix) { 'true' } else { 'false' }
$env:removeNewVersionNotif = if ($removeNotif) { 'true' } else { 'false' }
$env:xOffline=(Cfg 'xOffline' 'false'); $env:hidecm=(Cfg 'hidecm' 'false')
$env:iconlink_url='false'; $env:logolink_url='false'; $env:privacylink_url='false'
$env:RD_PATCHES=$Patches; $env:uuid=$uuid; $env:version=$version

$bash = 'C:\mingit\usr\bin\bash.exe'
if (Test-Path $bash) {
    Try-Step { & $bash -lc "cd '$($Src -replace '\\','/')' && . C:/rdgen/scripts/customize.sh && customize_common" }
} else {
    Warn 'bash not found in image; applying minimal PowerShell fallbacks'
    Try-Step { (Get-Content ./libs/hbb_common/src/config.rs) -replace 'rs-ny.rustdesk.com', $server | Set-Content ./libs/hbb_common/src/config.rs }
    Try-Step { (Get-Content ./libs/hbb_common/src/config.rs) -replace 'OeVuKk5nlHiXp\+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=', $key | Set-Content ./libs/hbb_common/src/config.rs }
}

# --- flutter engine + bridge ------------------------------------------------
Report 'Generating flutter-rust bridge'
Try-Step {
    Push-Location flutter
    (Get-Content pubspec.yaml) -replace 'extended_text: 14.0.0', 'extended_text: 13.0.0' | Set-Content pubspec.yaml
    flutter pub get
    Pop-Location
    flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
}

# --- vcpkg ------------------------------------------------------------------
Report 'Installing vcpkg dependencies'
$env:VCPKG_ROOT = 'C:\vcpkg'
Try-Step { & C:\vcpkg\vcpkg.exe install --triplet x64-windows-static --x-install-root C:\vcpkg\installed }

# --- build ------------------------------------------------------------------
Report 'Compiling RustDesk (this is the long part)'
Set-Content -Path ./rustdesk_custom.txt -Value $custom -NoNewline
python .\build.py --portable --hwcodec --flutter --vram --skip-portable-pack
Move-Item -Force ./flutter/build/windows/x64/runner/Release ./rustdesk
Copy-Item -Force ./rustdesk_custom.txt ./rustdesk/custom_.txt

Report 'Packaging (.exe / .msi)'
if ($appname -ne 'rustdesk') {
    Try-Step { Move-Item -Force "./rustdesk/rustdesk.exe" "./rustdesk/$appname.exe" }
}
$exeName = if ($appname -ne 'rustdesk') { "$appname.exe" } else { 'rustdesk.exe' }

Try-Step {
    (Get-Content res/manifest.xml) | Where-Object { $_ -notmatch 'dpiAware' } | Set-Content res/manifest.xml
    Push-Location ./libs/portable
    pip install -r requirements.txt
    python ./generate.py -f ../../rustdesk/ -o . -e "../../rustdesk/$exeName"
    Pop-Location
    New-Item -ItemType Directory -Force -Path ./SignOutput | Out-Null
    Move-Item -Force ./target/release/rustdesk-portable-packer.exe "./SignOutput/$filename.exe"
}

# msi
Try-Step {
    $myapp = $appname -replace '\s', '_'
    Copy-Item "rustdesk/$exeName" "rustdesk/$myapp.exe" -ErrorAction SilentlyContinue
    Push-Location ./res/msi
    python preprocess.py --app-name "$myapp" --arp -d ../../rustdesk
    & C:\tools\nuget.exe restore msi.sln
    $msbuild = & "C:\BuildTools\MSBuild\Current\Bin\MSBuild.exe" msi.sln -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10
    Copy-Item ./Package/bin/x64/Release/en-us/Package.msi "../../SignOutput/$filename.msi"
    Pop-Location
}

Report 'Uploading artifacts'
Upload "./SignOutput/$filename.exe"
Upload "./SignOutput/$filename.msi"

Copy-Item ./SignOutput/* $Out -Force -ErrorAction SilentlyContinue
Report 'success'
Log "Windows build finished. Artifacts in $Out"
Get-ChildItem $Out | Format-Table -AutoSize
