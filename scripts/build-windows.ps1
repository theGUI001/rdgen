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
$Patches = if ($env:RD_PATCHES) { $env:RD_PATCHES } else { 'C:\patches' }

function Log($m)  { Write-Host "[rdgen] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[rdgen] $m" -ForegroundColor Yellow }
function Try-Step([scriptblock]$b) {
    try { & $b } catch { Warn "step failed (ignored): $($_.Exception.Message)" }
}

# Tool discovery: prefer whatever is on PATH / discoverable (native host, e.g. a
# Hyper-V VM) and fall back to the fixed paths baked into the container image.
function Find-Tool($name, [string[]]$fallbacks) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($f in $fallbacks) { if (Test-Path $f) { return $f } }
    return $null
}

function Find-MSBuild {
    $vswhere = Find-Tool 'vswhere.exe' @("${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe")
    if ($vswhere) {
        $p = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
            -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
        if ($p) { return $p }
    }
    return (Find-Tool 'MSBuild.exe' @('C:\BuildTools\MSBuild\Current\Bin\MSBuild.exe'))
}

function Load-VsDevEnv {
    $vcvars = Find-Tool 'vcvarsall.bat' @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat"
    )
    if (-not $vcvars) {
        $found = Get-ChildItem "C:\Program Files*\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvarsall.bat" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $vcvars = $found.FullName }
    }
    if ($vcvars) {
        Log "Loading MSVC build environment from $vcvars"
        $envLines = cmd.exe /c "call `"$vcvars`" x64 & set"
        foreach ($line in $envLines) {
            if ($line -match "^([^=]+)=(.*)$") {
                $varName = $matches[1]
                $varValue = $matches[2]
                [Environment]::SetEnvironmentVariable($varName, $varValue, "Process")
            }
        }
    } else {
        Warn "vcvarsall.bat not found; MSVC build environment might be missing INCLUDE/LIB variables"
    }
}

$BashExe   = Find-Tool 'bash.exe'   @('C:\mingit\usr\bin\bash.exe', "$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe")
$NugetExe  = Find-Tool 'nuget.exe'  @('C:\rdgen-tools\tools\nuget.exe', 'C:\tools\nuget.exe')
$MSBuildExe = Find-MSBuild

Load-VsDevEnv

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
$env:iconlink_url=(Cfg 'iconlink_url' 'false'); $env:logolink_url=(Cfg 'logolink_url' 'false'); $env:privacylink_url=(Cfg 'privacylink_url' 'false')
$env:RD_PATCHES=$Patches; $env:uuid=$uuid; $env:version=$version; $env:RD_CONFIG=$Config

# customize.sh lives next to this script (works in-container and natively).
$customizeSh = Join-Path $PSScriptRoot 'customize.sh'
if (-not (Test-Path $customizeSh)) { $customizeSh = 'C:/rdgen/scripts/customize.sh' }
if ($BashExe) {
    $shPath = ($customizeSh -replace '\\','/')
    Try-Step { & $BashExe -lc "cd '$($Src -replace '\\','/')' && . '$shPath' && customize_common" }
} else {
    Warn 'bash (Git for Windows) not found; applying minimal PowerShell fallbacks only'
    Try-Step { (Get-Content ./libs/hbb_common/src/config.rs) -replace 'rs-ny.rustdesk.com', $server | Set-Content ./libs/hbb_common/src/config.rs }
    Try-Step { (Get-Content ./libs/hbb_common/src/config.rs) -replace 'OeVuKk5nlHiXp\+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=', $key | Set-Content ./libs/hbb_common/src/config.rs }
}

Report 'Processing custom icons'
Try-Step { python (Join-Path $PSScriptRoot 'process_icons.py') $Config $Src }

# --- flutter engine + bridge ------------------------------------------------
Report 'Generating flutter-rust bridge'
Try-Step {
    Push-Location flutter
    flutter pub get
    Pop-Location
    flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
}

# --- vcpkg ------------------------------------------------------------------
Report 'Installing vcpkg dependencies'
if (Test-Path 'C:\rdgen-tools\vcpkg\vcpkg.exe') {
    $env:VCPKG_ROOT = 'C:\rdgen-tools\vcpkg'
} elseif (Test-Path 'C:\vcpkg\vcpkg.exe') {
    $env:VCPKG_ROOT = 'C:\vcpkg'
}
if (Test-Path 'C:\rdgen-tools\tools') {
    $env:PATH = "C:\rdgen-tools\tools;$env:PATH"
}
$vcpkgExe = Join-Path $env:VCPKG_ROOT 'vcpkg.exe'
$overlayPorts = Join-Path $Src 'res\vcpkg'
if (Test-Path $overlayPorts) {
    Try-Step { & $vcpkgExe install --triplet x64-windows-static --host-triplet x64-windows-static --overlay-ports="$overlayPorts" --x-install-root (Join-Path $env:VCPKG_ROOT 'installed') }
} else {
    Try-Step { & $vcpkgExe install --triplet x64-windows-static --host-triplet x64-windows-static --x-install-root (Join-Path $env:VCPKG_ROOT 'installed') }
}

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
if (-not $NugetExe)  { Warn 'nuget.exe not found; skipping .msi' }
elseif (-not $MSBuildExe) { Warn 'MSBuild not found; skipping .msi' }
else {
    Try-Step {
        $myapp = $appname -replace '\s', '_'
        Copy-Item "rustdesk/$exeName" "rustdesk/$myapp.exe" -ErrorAction SilentlyContinue
        Push-Location ./res/msi
        python preprocess.py --app-name "$myapp" --arp -d ../../rustdesk
        & $NugetExe restore msi.sln
        & $MSBuildExe msi.sln -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10
        Copy-Item ./Package/bin/x64/Release/en-us/Package.msi "../../SignOutput/$filename.msi"
        Pop-Location
    }
}

Report 'Uploading artifacts'
Upload "./SignOutput/$filename.exe"
Upload "./SignOutput/$filename.msi"

Copy-Item ./SignOutput/* $Out -Force -ErrorAction SilentlyContinue
Report 'success'
Log "Windows build finished. Artifacts in $Out"
Get-ChildItem $Out | Format-Table -AutoSize
