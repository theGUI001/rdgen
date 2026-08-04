# RDGen, a RustDesk client generator to use with your self-hosted RustDesk server

The client generator is currently hosted [here](https://rdgen.crayoneater.org).
If you would like to host the generator yourself, see [here](setup.md)

## Features

- Embed server and key into client
- Custom app name
- Custom icon/logo
- Set default settings for the client
- Support for rustdesk advanced settings (https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/)

## Building custom clients yourself (Docker, native, and the multi-build screen)

Beyond the original "dispatch a GitHub Actions workflow" flow, this fork can
build every supported platform **on your own machines**: in Docker where that
works, natively where Apple and Microsoft leave no choice. There is also a
**multi-build screen** in the web app that queues several platforms from one
form. Full details in [`docs/BUILDS.md`](docs/BUILDS.md); everything you need to
run a build is below.

### What builds where

| Platform | Docker | Native | Artifacts | Notes |
|----------|--------|--------|-----------|-------|
| **Linux** | ✅ any Docker host | – | `.deb` + `.rpm` | the easy one; works on Docker Desktop / WSL2 |
| **Android** | ✅ any Docker host | – | one `.apk` per ABI | same image workflow as Linux |
| **Windows** | ⚠️ only on a Windows host in *Windows containers* mode | ✅ `scripts/windows/` | `.exe` + `.msi` | Windows containers can't run under WSL2, so native in a VM is the practical path |
| **macOS** | ❌ impossible | ✅ `scripts/macos/` | `.dmg` | Xcode/codesign only run on macOS, and macOS only virtualises on Apple hardware |
| **iOS** | ❌ | ❌ | – | not supported by this build system |

Everything is **local-first**: builder images are built on your machine the
first time and reused; nothing is pulled from a registry unless you ask with
`--registry`. Expect **30–45 minutes** for a first build (plus image build time),
much less afterwards thanks to the cached image and vcpkg tree.

---

### Step 0 — the `build.json` every build reads (do this once)

All four platforms take the same config file, so this step is shared.

```bash
git clone https://github.com/theGUI001/rdgen && cd rdgen
cp scripts/config.example.json build.json
$EDITOR build.json
```

The fields that matter most:

| Key | What it does |
|-----|--------------|
| `platform` | overridden per build, so it doesn't matter here |
| `version` | RustDesk tag to build (`1.4.9`, …) or `master` for nightly |
| `server` / `key` / `apiServer` | your self-hosted RustDesk server and its public key |
| `appname` | display name baked into the client |
| `filename` | base name of the produced files (`acme-remote` → `acme-remote-x86_64.deb`) |
| `compname` | company name shown in the UI |
| `androidappid` | Android application id (Android only) |
| `custom` | base64 blob of default/override settings — easiest way to get one is to fill the web form and save its config |
| `android_abis` | which ABIs to build, default `arm64-v8a,armeabi-v7a,x86_64` |

Any field can also be overridden on the command line without touching the file:

```bash
scripts/rdbuild.sh --platforms linux \
    --appname "Acme Remote" --filename acme-remote \
    --server rs.acme.com --apiServer https://api.acme.com
```

Artifacts always land in **`./output/<platform>/`**.

---

### Linux — step by step (Docker)

**Requirements:** Docker (any host: Linux, macOS, Windows with WSL2). Nothing
else — Rust, Flutter, vcpkg and the rest live inside the image.

```bash
# 1) Build. The first run builds the ~Ubuntu-18.04-based builder image
#    (slow, once), then compiles RustDesk inside it.
scripts/rdbuild.sh --config build.json --platforms linux

# 2) Collect the artifacts
ls output/linux/
#   acme-remote-x86_64.deb
#   acme-remote-x86_64.rpm
```

Useful flags:

```bash
# Rebuild the builder image after editing docker/linux-builder.Dockerfile
scripts/rdbuild.sh --config build.json --platforms linux --rebuild-image

# Write artifacts somewhere else
scripts/rdbuild.sh --config build.json --platforms linux --output /srv/builds
```

The image targets old glibc, so the `.deb`/`.rpm` install on distributions far
older than your host.

---

### Android — step by step (Docker)

**Requirements:** Docker, and a good amount of free disk — the image carries the
Android SDK, the NDK and Flutter.

```bash
# 1) Optional: pick the ABIs in build.json (default is all three)
#    "android_abis": "arm64-v8a,armeabi-v7a,x86_64"

# 2) Build
scripts/rdbuild.sh --config build.json --platforms android

# 3) Collect
ls output/android/
#   acme-remote-aarch64.apk
#   acme-remote-armv7.apk
#   acme-remote-x86_64.apk
```

APKs are signed with the **debug** key, which is enough to sideload. To ship
through a store, re-sign them with your own keystore (`apksigner sign …`).

Cutting the ABI list to just `arm64-v8a` roughly thirds the build time.

---

### Windows — step by step

Two paths; pick by what host you have.

#### Path A — Docker (only on a Windows host in "Windows containers" mode)

```bash
# Docker Desktop → right-click the tray icon → "Switch to Windows containers…"
# then, from Git Bash on that same Windows host:
scripts/rdbuild.sh --config build.json --platforms windows
```

This does **not** work under WSL2 or on a Linux/macOS host: a Windows container
needs a Windows kernel.

#### Path B — native in a Windows VM (recommended, e.g. Hyper-V)

**Requirements:** Windows 10/11 (a VM is fine), administrator rights for the
first step, and plenty of free disk — MSVC Build Tools, Flutter and the vcpkg
tree are all large.

```powershell
# 1) One-time, in an ELEVATED PowerShell: installs MSVC Build Tools, Git,
#    Python, LLVM, Rust, Flutter (+ the RustDesk engine), vcpkg and nuget.
#    -Persist writes the environment variables machine-wide.
powershell -ExecutionPolicy Bypass -File scripts\windows\setup-toolchain.ps1 -Persist

# 2) Open a FRESH shell (so it picks up the new PATH), then build:
powershell -ExecutionPolicy Bypass -File scripts\windows\build-windows-native.ps1 `
    -Config .\build.json -Output .\output

#    Or do both in one go the first time:
powershell -ExecutionPolicy Bypass -File scripts\windows\build-windows-native.ps1 `
    -Config .\build.json -Setup
```

```
output\
  acme-remote.exe    # portable, self-extracting
  acme-remote.msi    # installer
```

If the `.msi` is missing from the output, `nuget.exe` or MSBuild wasn't found —
re-run step 1 and check its log; the `.exe` is produced either way.

---

### macOS — step by step (native only)

**Requirements:** a Mac — bare metal or a VM **on Apple hardware** (UTM,
Parallels, VMware Fusion, or `tart` for a headless setup — give the guest
generous RAM and disk, the toolchain and vcpkg tree are large). Homebrew
installed. Docker is *not* used and *not* required.

```bash
# 1) One-time: install/verify the toolchain. Everything already present is
#    skipped — an existing Flutter or Rust on PATH is reused untouched.
scripts/macos/setup-toolchain.sh

# 2) Build
scripts/macos/build-macos-native.sh --config ./build.json --output ./output

#    Or both at once the first time:
scripts/macos/build-macos-native.sh --config ./build.json --setup

# 3) Collect — one DMG, for this machine's architecture
ls output/macos/
#   acme-remote-aarch64.dmg     (Apple silicon)   or
#   acme-remote-x86_64.dmg      (Intel)
```

Step 1 installs, skipping anything already there: Xcode command line tools,
imagemagick, potrace, cmake, ninja, pkg-config, llvm, create-dmg, CocoaPods,
**NASM 2.16** (*not* Homebrew's 3.x, which breaks ffmpeg's assembly), Rust + the
host target, Flutter 3.24.5 with the RustDesk patches, vcpkg and
`flutter_rust_bridge_codegen`. It writes `~/rdgen-tools/env.sh`, which the build
script sources automatically.

**Signing.** The DMG is **ad-hoc signed** by default: it runs on this Mac, but
other Macs show Gatekeeper's "unidentified developer" warning (users can bypass
it with `xattr -cr /Applications/<App>.app`). For a real Developer ID:

```bash
brew install rcodesign
export MACOS_P12_FILE=/path/to/certificate.p12
export MACOS_P12_PASSWORD='…'
scripts/macos/build-macos-native.sh --config ./build.json
```

Notarisation isn't automated — run `xcrun notarytool submit` on the DMG if you
need it.

`scripts/rdbuild.sh --platforms macos` also works **on a Mac**: it detects macOS
and delegates to the native script, so `--platforms linux,macos` builds Linux in
a container and macOS natively in one command. Docker is only required if the
list contains something other than `macos`.

| Env var | Meaning |
|---------|---------|
| `MACOS_P12_FILE` / `MACOS_P12_PASSWORD` | Developer ID certificate; ad-hoc signing when unset |
| `MIN_MACOS_VERSION` | deployment target on Apple silicon (default `12.3`) |
| `RDGEN_INSTALL_ROOT` | where vcpkg / a managed Flutter go (default `~/rdgen-tools`) |

---

### The multi-build screen (`/batch`) — step by step

Same builds, driven from the web UI: fill the client configuration **once** and
queue every platform you want.

**1. Run the web app in local mode.** `BUILD_ENGINE=local` is what makes the
site build on its own machine instead of dispatching GitHub Actions:

```bash
pip install -r requirements.txt
python manage.py migrate

export BUILD_ENGINE=local
python manage.py runserver 0.0.0.0:8000
```

| Env var | Default | Meaning |
|---------|---------|---------|
| `BUILD_ENGINE` | `github` | `local` runs builds on this machine |
| `RDGEN_REPO_ROOT` | project dir | where `scripts/` lives and artifacts are written |
| `LOCAL_BUILD_PLATFORMS` | `linux,android,windows` (+ `macos` on a Mac) | platforms the local engine may build |

**2. Open the screen.** Go to <http://localhost:8000/batch>, or click
*"Schedule builds for multiple platforms at once"* on the builder page.

**3. Tick the platforms.** Linux, Windows and Android are always offered. A
**macOS** card appears when the app is running on a Mac — that one build runs
natively while the others use Docker. What each host can actually do:

| Host running the app | Cards you can use |
|----------------------|-------------------|
| Linux / WSL2 + Docker | Linux, Android |
| Windows + Docker Desktop (Windows containers) | Linux, Android, Windows |
| Windows VM without Docker | Windows (native) |
| Mac + Docker | Linux, Android, **macOS** (native) |

Ticking a platform this host can't build isn't fatal — that job fails with a
clear message while the others finish.

**4. Fill the configuration once** — server, key, app name, icon, default
settings — plus an optional *batch label* to recognise the run later. These
values apply to every platform in the batch.

**5. Hit "Schedule builds".** You land on a live dashboard that polls each job
until it finishes, showing:

- per-platform status (queued → running → success/failure),
- a **build log** link (`/local_log?uuid=…`, plain text, updates as it runs),
- **download links** for each artifact once a job succeeds.

Builds run one background thread per job, so several platforms progress at once
— on one machine they'll compete for CPU, so queueing four at a time on a laptop
is slower than it looks.

**6. Download.** Links point at `/download?uuid=…&filename=…`; the same files are
also on disk under `exe/<uuid>/`. The dashboard offers every name a platform
*can* produce, so a link 404s when that particular artifact wasn't built (e.g.
the Intel DMG on an Apple-silicon Mac) — that's expected.

The single-build page (`/`) works the same way and accepts macOS too when the
app runs on a Mac; the batch screen just saves you filling the form four times.

---

### Optional: build on GitHub Actions instead

If you *do* want CI, run **Build Docker Builder Images** (`builder-images.yml`)
once to publish the toolchain images to GHCR, then the web app dispatches
**`docker-generator.yml`**, which builds inside those containers. macOS still
needs `generator-macos.yml` on a macOS runner.

These build workflows are **off by default** — they refuse to run unless the
repository variable `RDGEN_ENABLE_CI` is set to `true`.

#### Turning GitHub Actions off completely (public fork)

A fork of a public repo can't be made private, so to be sure **no CI ever runs**
(nobody burns your Actions minutes, no artifacts leak through a workflow run):

> **Settings → Actions → General → Actions permissions → "Disable actions" → Save**

That one owner-only switch makes every workflow inert. Combined with the local
builds above you get the full generator with zero GitHub CI. Note that with
Actions disabled the web app must run in `BUILD_ENGINE=local` mode, since the
default `github` engine has nothing to dispatch to.

### Files added by this system

| Path | Purpose |
|------|---------|
| `docker/*.Dockerfile` | Linux / Android / Windows builder toolchain images |
| `scripts/customize.sh` | all source-level whitelabelling, shared by every platform |
| `scripts/build-{linux,android,macos}.sh`, `build-windows.ps1` | per-platform build + package |
| `scripts/rdbuild.sh` | local orchestrator (multi-platform, `docker run` + native macOS) |
| `scripts/windows/*.ps1` | native Windows toolchain setup + build (no Docker) |
| `scripts/macos/*.sh` | native macOS toolchain setup + build (no Docker) |
| `scripts/config.example.json` | annotated example `build.json` |
| `rdgenerator/local_runner.py` | runs builds locally for `BUILD_ENGINE=local` |
| `.github/workflows/builder-images.yml` | build & push images to GHCR |
| `.github/workflows/docker-generator.yml` | containerised build workflow |
| `docs/BUILDS.md` | full documentation |

## Generate RustDesk clients from command line instead of using a web browser

Save your configuration from the rdgen web interface, or generate your own, then use that json file with [@AlekseyLapunov's rdgen-cli](https://github.com/AlekseyLapunov/rdgen-cli) to build from the command line on Windows, Linux, or MacOS like this: `python rdgen-cli -f my_config.json --set-version 1.4.5 --set-platform windows -s https://rdgen.crayoneater.org`

## Notes

- Icons should be square (256x256 recommended)
- Avoid special characters or non-English characters in app name and file name
- Build time is currently 30 - 45 minutes

