# RDGen, a RustDesk client generator to use with your self-hosted RustDesk server

The client generator is currently hosted [here](https://rdgen.crayoneater.org).
If you would like to host the generator yourself, see [here](setup.md)

## Features

- Embed server and key into client
- Custom app name
- Custom icon/logo
- Set default settings for the client
- Support for rustdesk advanced settings (https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/)

## Docker-based & local builds, and multi-platform batch scheduling

Beyond the original "dispatch a GitHub Actions workflow" flow, this fork adds a
**containerised build system**, a way to **build entirely locally** (no GitHub),
a **batch scheduler** to queue several platforms at once, and a **native Windows
build** for a Hyper-V VM. Everything below is documented in depth in
[`docs/BUILDS.md`](docs/BUILDS.md); this section is the quick reference.

> **Platform support:** Linux, Windows and Android can be built with Docker
> and/or locally. **macOS and iOS cannot** — Apple's toolchain only runs on
> macOS, so those still need the `generator-macos.yml` workflow on a macOS
> runner. The batch UI and local tools skip Apple targets with a clear message.

### At a glance

| I want to… | Use |
|------------|-----|
| Build several OSes in one go from the web UI | **Batch scheduler** at `/batch` |
| Build on my own machine, no GitHub at all | **`scripts/rdbuild.sh`** (Docker) |
| Run the web app so it builds locally | **`BUILD_ENGINE=local`** |
| Build Windows `.exe`/`.msi` without Docker | **`scripts/windows/`** (native, e.g. Hyper-V) |
| Guarantee nobody runs CI on my public fork | **Disable Actions** in repo settings |
| Still use GitHub Actions, but containerised | **`docker-generator.yml`** + **`builder-images.yml`** |

### 1. Batch scheduler (web UI)

Open `/batch` (or the *"Schedule builds for multiple platforms at once"* button
on the builder page). Tick Linux / Windows / Android, fill in the client
configuration **once**, and hit **Schedule builds**. You land on a live
dashboard that polls every build until it finishes, with per-platform status,
a build-log link and download links.

### 2. Local builds with `scripts/rdbuild.sh` (no GitHub)

Local-first: it builds the toolchain image on your machine the first time and
reuses it. Nothing is pulled from a registry unless you ask.

```bash
# Two platforms in one go, from a config file:
scripts/rdbuild.sh --config build.json --platforms linux,android

# Override any build.json field on the command line:
scripts/rdbuild.sh --platforms linux \
    --appname "Acme Remote" --filename acme-remote \
    --server rs.acme.com --apiServer https://api.acme.com

# Rebuild the builder image (e.g. after editing a Dockerfile):
scripts/rdbuild.sh --config build.json --platforms linux --rebuild-image
```

Artifacts land in `./output/<platform>/`. Copy `scripts/config.example.json` to
start your own `build.json`. On **Docker Desktop / WSL2**, Linux and Android
build fine; Windows needs a Windows host in "Windows containers" mode (see #4).

### 3. Run the web app in local mode (`BUILD_ENGINE=local`)

Set one env var and the site executes builds on its own machine instead of
dispatching GitHub Actions:

```bash
export BUILD_ENGINE=local
```

Both the single builder and the batch scheduler then run `scripts/rdbuild.sh`
locally in a background thread. The waiting page, batch dashboard and
`/download` links all work unchanged; a plain-text log is at
`/local_log?uuid=<uuid>`. Relevant env vars:

| Env var | Default | Meaning |
|---------|---------|---------|
| `BUILD_ENGINE` | `github` | `local` runs builds on this machine |
| `RDGEN_REPO_ROOT` | project dir | where `scripts/` lives and artifacts are written |
| `LOCAL_BUILD_PLATFORMS` | `linux,android,windows` | platforms the local engine may build |

### 4. Native Windows build (no Docker) — for a Hyper-V VM

Windows containers can't run under WSL2, so for Windows the simplest local path
is a native build inside a Windows VM. Scripts live in `scripts/windows/`:

```powershell
# 1) One-time, elevated: install the toolchain (MSVC, Rust, Flutter, LLVM, vcpkg…).
powershell -ExecutionPolicy Bypass -File scripts\windows\setup-toolchain.ps1 -Persist

# 2) Build from a config (in a fresh shell after step 1):
powershell -ExecutionPolicy Bypass -File scripts\windows\build-windows-native.ps1 `
    -Config .\build.json -Output .\output
```

If the web app runs inside that same VM with `BUILD_ENGINE=local`, it calls the
native Windows build automatically for `windows` targets.

### 5. Containerised GitHub Actions (optional)

If you *do* want CI: run **Build Docker Builder Images** (`builder-images.yml`)
once to publish the toolchain images to GHCR, then the web app dispatches
**`docker-generator.yml`**, which builds inside those containers.

These build workflows are **off by default** — they refuse to run unless the
repository variable `RDGEN_ENABLE_CI` is set to `true`.

### Turning GitHub Actions off completely (public fork)

A fork of a public repo can't be made private, so to be sure **no CI ever runs**
(nobody burns your Actions minutes, no artifacts leak through a workflow run):

> **Settings → Actions → General → Actions permissions → "Disable actions" → Save**

That one owner-only switch makes every workflow inert. Combined with local
builds (#2/#3/#4) you get the full generator with zero GitHub CI. Note that
with Actions disabled the web app must run in `BUILD_ENGINE=local` mode, since
the default `github` engine has nothing to dispatch to.

### Files added by this system

| Path | Purpose |
|------|---------|
| `docker/*.Dockerfile` | Linux / Android / Windows builder toolchain images |
| `scripts/customize.sh` | all source-level whitelabelling, shared by every platform |
| `scripts/build-{linux,android}.sh`, `build-windows.ps1` | per-platform build + package |
| `scripts/rdbuild.sh` | local orchestrator (multi-platform `docker run`) |
| `scripts/windows/*.ps1` | native Windows toolchain setup + build (no Docker) |
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

