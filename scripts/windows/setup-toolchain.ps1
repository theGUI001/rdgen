<#
.SYNOPSIS
    Install the RustDesk Windows build toolchain natively (no Docker).

.DESCRIPTION
    Mirrors docker/windows-builder.Dockerfile but installs onto a real Windows
    host — e.g. a Hyper-V VM — so you can build the .exe/.msi without Docker.
    Installs: Visual Studio Build Tools (MSVC + Windows SDK + ATL/MFC), Git,
    Python, LLVM, Rust (rustup), Flutter (+ RustDesk engine), vcpkg and nuget,
    plus the flutter_rust_bridge codegen.

    Idempotent-ish: each component is skipped if already present. Sets the
    required environment variables for the current session, and (with -Persist)
    for the machine so future sessions inherit them.

.EXAMPLE
    # Run once, elevated, in the VM:
    powershell -ExecutionPolicy Bypass -File scripts\windows\setup-toolchain.ps1 -Persist
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\rdgen-tools',
    [string]$RustVersion = '1.75',
    [string]$FlutterVersion = '3.24.5',
    [string]$LlvmVersion = '15.0.6',
    [string]$VcpkgCommit = '120deac3062162151622ca4860575a33844ba10b',
    [string]$PythonVersion = '3.11.9',
    [switch]$Persist
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Log($m) { Write-Host "[setup] $m" -ForegroundColor Cyan }
function Have($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$dl = Join-Path $InstallRoot 'downloads'
New-Item -ItemType Directory -Force -Path $dl | Out-Null

$FlutterHome = Join-Path $InstallRoot 'flutter'
$CargoHome   = Join-Path $InstallRoot 'cargo'
$RustupHome  = Join-Path $InstallRoot 'rustup'
$VcpkgRoot   = Join-Path $InstallRoot 'vcpkg'
$Tools       = Join-Path $InstallRoot 'tools'
New-Item -ItemType Directory -Force -Path $Tools | Out-Null

# --- Visual Studio Build Tools ---------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    Log 'Visual Studio Build Tools already present'
} else {
    Log 'Installing Visual Studio Build Tools (this is large and slow)'
    $vs = Join-Path $dl 'vs_buildtools.exe'
    Invoke-WebRequest -Uri https://aka.ms/vs/17/release/vs_buildtools.exe -OutFile $vs
    Start-Process -FilePath $vs -Wait -NoNewWindow -ArgumentList @(
        '--quiet','--wait','--norestart','--nocache',
        '--add','Microsoft.VisualStudio.Workload.VCTools',
        '--add','Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add','Microsoft.VisualStudio.Component.Windows11SDK.22621',
        '--add','Microsoft.VisualStudio.Component.VC.ATL',
        '--add','Microsoft.VisualStudio.Component.VC.ATLMFC',
        '--add','Microsoft.VisualStudio.Component.VC.CMake.Project',
        '--includeRecommended'
    )
}

# --- Git --------------------------------------------------------------------
if (Have 'git') { Log 'Git already present' }
else {
    Log 'Installing Git for Windows'
    $git = Join-Path $dl 'git.exe'
    Invoke-WebRequest -Uri https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/Git-2.45.2-64-bit.exe -OutFile $git
    Start-Process -FilePath $git -Wait -ArgumentList '/VERYSILENT','/NORESTART'
}

# --- Python -----------------------------------------------------------------
if (Have 'python') { Log 'Python already present' }
else {
    Log "Installing Python $PythonVersion"
    $py = Join-Path $dl 'python.exe'
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe" -OutFile $py
    Start-Process -FilePath $py -Wait -ArgumentList '/quiet','InstallAllUsers=1','PrependPath=1','Include_pip=1'
}

# --- LLVM -------------------------------------------------------------------
if (Test-Path 'C:\Program Files\LLVM\bin\libclang.dll') { Log 'LLVM already present' }
else {
    Log "Installing LLVM $LlvmVersion"
    $llvm = Join-Path $dl 'llvm.exe'
    Invoke-WebRequest -Uri "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/LLVM-$LlvmVersion-win64.exe" -OutFile $llvm
    Start-Process -FilePath $llvm -Wait -ArgumentList '/S'
}
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'

# --- Rust -------------------------------------------------------------------
$env:CARGO_HOME = $CargoHome
$env:RUSTUP_HOME = $RustupHome
if (Test-Path (Join-Path $CargoHome 'bin\cargo.exe')) { Log 'Rust already present' }
else {
    Log "Installing Rust $RustVersion"
    $rustup = Join-Path $dl 'rustup-init.exe'
    Invoke-WebRequest -Uri https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe -OutFile $rustup
    Start-Process -FilePath $rustup -Wait -NoNewWindow -ArgumentList `
        '-y','--default-toolchain',$RustVersion,'--default-host','x86_64-pc-windows-msvc','--profile','minimal','--component','rustfmt'
}
$env:PATH = "$CargoHome\bin;$env:PATH"

# --- nuget ------------------------------------------------------------------
if (-not (Test-Path (Join-Path $Tools 'nuget.exe'))) {
    Log 'Installing nuget'
    Invoke-WebRequest -Uri https://dist.nuget.org/win-x86-commandline/latest/nuget.exe -OutFile (Join-Path $Tools 'nuget.exe')
}

# --- Flutter ----------------------------------------------------------------
if (Test-Path (Join-Path $FlutterHome 'bin\flutter.bat')) { Log 'Flutter already present' }
else {
    Log "Installing Flutter $FlutterVersion"
    $fl = Join-Path $dl 'flutter.zip'
    Invoke-WebRequest -Uri "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$FlutterVersion-stable.zip" -OutFile $fl
    Expand-Archive $fl -DestinationPath $InstallRoot -Force
}
$env:PATH = "$FlutterHome\bin;$env:PATH"
git config --global --add safe.directory '*' | Out-Null
& (Join-Path $FlutterHome 'bin\flutter.bat') config --no-analytics | Out-Null
& (Join-Path $FlutterHome 'bin\flutter.bat') precache --windows | Out-Null

# RustDesk custom engine + dropdown patch.
Log 'Applying RustDesk Flutter engine + patch'
$engineDir = Join-Path $FlutterHome "bin\cache\artifacts\engine\windows-x64-release"
try {
    $eng = Join-Path $dl 'engine.zip'
    Invoke-WebRequest -Uri https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip -OutFile $eng
    New-Item -ItemType Directory -Force -Path $engineDir | Out-Null
    Expand-Archive $eng -DestinationPath (Join-Path $dl 'engine') -Force
    Copy-Item (Join-Path $dl 'engine\*') $engineDir -Recurse -Force
} catch { Log "engine replace skipped: $($_.Exception.Message)" }

$patch = Join-Path $PSScriptRoot '..\..\.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff'
if ((Test-Path $patch) -and ($FlutterVersion -eq '3.24.5')) {
    Push-Location $FlutterHome
    try { git apply $patch } catch { Log 'flutter patch already applied or not needed' }
    Pop-Location
}

# --- vcpkg ------------------------------------------------------------------
$env:VCPKG_ROOT = $VcpkgRoot
if (Test-Path (Join-Path $VcpkgRoot 'vcpkg.exe')) { Log 'vcpkg already present' }
else {
    Log 'Bootstrapping vcpkg'
    git clone https://github.com/microsoft/vcpkg $VcpkgRoot
    Push-Location $VcpkgRoot
    git checkout $VcpkgCommit
    & (Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
    Pop-Location
}

# --- flutter_rust_bridge codegen -------------------------------------------
if (-not (Test-Path (Join-Path $CargoHome 'bin\flutter_rust_bridge_codegen.exe'))) {
    Log 'Installing flutter_rust_bridge_codegen (compiles from source, slow)'
    cargo install cargo-expand --version 1.0.95 --locked
    cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked
}

# --- persist env ------------------------------------------------------------
if ($Persist) {
    Log 'Persisting environment variables to Machine scope'
    [Environment]::SetEnvironmentVariable('CARGO_HOME', $CargoHome, 'Machine')
    [Environment]::SetEnvironmentVariable('RUSTUP_HOME', $RustupHome, 'Machine')
    [Environment]::SetEnvironmentVariable('VCPKG_ROOT', $VcpkgRoot, 'Machine')
    [Environment]::SetEnvironmentVariable('LIBCLANG_PATH', 'C:\Program Files\LLVM\bin', 'Machine')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    foreach ($p in @("$CargoHome\bin", "$FlutterHome\bin", $Tools, 'C:\Program Files\LLVM\bin')) {
        if ($machinePath -notlike "*$p*") { $machinePath = "$p;$machinePath" }
    }
    [Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
}

# Write a small env file the build wrapper can dot-source in this session.
$envFile = Join-Path $InstallRoot 'env.ps1'
@"
`$env:CARGO_HOME   = '$CargoHome'
`$env:RUSTUP_HOME  = '$RustupHome'
`$env:VCPKG_ROOT   = '$VcpkgRoot'
`$env:LIBCLANG_PATH= 'C:\Program Files\LLVM\bin'
`$env:PATH = '$CargoHome\bin;$FlutterHome\bin;$Tools;C:\Program Files\LLVM\bin;' + `$env:PATH
"@ | Set-Content -Path $envFile -Encoding UTF8

Log "Toolchain ready. Environment file: $envFile"
Log 'Open a NEW shell (or dot-source that env file) before building.'
