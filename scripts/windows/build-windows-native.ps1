<#
.SYNOPSIS
    Build a customised RustDesk Windows client natively (no Docker).

.DESCRIPTION
    Intended for a Windows host or Hyper-V VM. It sets up a work directory,
    then reuses the shared build logic in scripts/build-windows.ps1 (which
    discovers the toolchain on PATH). Produces <filename>.exe and <filename>.msi
    in the -Output directory.

    Run setup-toolchain.ps1 once first (or pass -Setup here to do it inline).

.PARAMETER Config
    Path to a build.json (see scripts/config.example.json).

.PARAMETER Output
    Directory to place the finished artifacts in. Default: .\output\windows

.PARAMETER Setup
    Install the toolchain first via setup-toolchain.ps1.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\windows\build-windows-native.ps1 `
        -Config .\build.json -Output .\output
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [string]$Output = (Join-Path (Get-Location) 'output\windows'),
    [string]$WorkDir = (Join-Path $env:TEMP ("rdgen-" + [guid]::NewGuid().ToString('N').Substring(0,8))),
    [string]$InstallRoot = 'C:\rdgen-tools',
    [switch]$Setup
)

$ErrorActionPreference = 'Stop'
function Log($m) { Write-Host "[rdgen-native] $m" -ForegroundColor Green }

$ScriptDir = $PSScriptRoot
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..\..')

if (-not (Test-Path $Config)) { throw "config not found: $Config" }

if ($Setup) {
    Log 'Running toolchain setup...'
    & (Join-Path $ScriptDir 'setup-toolchain.ps1') -InstallRoot $InstallRoot
}

# Pull in the toolchain env if setup produced one (harmless if absent).
$envFile = Join-Path $InstallRoot 'env.ps1'
if (Test-Path $envFile) { Log "Loading toolchain env from $envFile"; . $envFile }

# Prepare the work directory the shared build script expects.
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $Output | Out-Null
Copy-Item $Config (Join-Path $WorkDir 'build.json') -Force

$env:RD_WORK    = $WorkDir
$env:RD_CONFIG  = (Join-Path $WorkDir 'build.json')
$env:RD_PATCHES = (Join-Path $RepoRoot '.github\patches')

Log "Work dir: $WorkDir"
Log 'Starting native Windows build (this takes a while)...'

# Reuse the shared build logic; it discovers MSBuild/nuget/bash/vcpkg on PATH.
& (Join-Path $RepoRoot 'scripts\build-windows.ps1')
$buildExit = $LASTEXITCODE

$produced = Join-Path $WorkDir 'output'
if (Test-Path $produced) {
    Copy-Item (Join-Path $produced '*') $Output -Recurse -Force -ErrorAction SilentlyContinue
}

if ($buildExit -and $buildExit -ne 0) {
    Log "Build reported a non-zero exit ($buildExit). Check the output above."
} else {
    Log "Done. Artifacts in: $Output"
    Get-ChildItem $Output -ErrorAction SilentlyContinue | Format-Table -AutoSize
}
