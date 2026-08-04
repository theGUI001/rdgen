# Docker-based custom RustDesk builds

This repo can build customised RustDesk clients **inside Docker containers**
instead of installing the whole toolchain on a GitHub Actions runner (or your
laptop) every time. The same containers power three things:

1. **`docker-generator.yml`** — a single GitHub Actions workflow that builds any
   supported platform in a container. It replaces the per-platform
   `generator-*.yml` workflows for Linux, Windows and Android.
2. **The batch scheduler** (`/batch` in the web app) — configure once, then
   queue builds for several operating systems back-to-back.
3. **`scripts/rdbuild.sh`** — build locally with plain `docker run`, no GitHub
   involved.

> **Platform reality check.** Linux, Windows and Android can be built in Docker.
> **macOS and iOS cannot** — Apple's toolchain only runs on macOS, so those
> targets still need the `generator-macos.yml` workflow on a macOS runner. The
> batch UI and `rdbuild.sh` both refuse Apple targets with a clear message
> rather than failing halfway through.

---

## Architecture

```
             ┌────────────────────────┐
             │  builder-images.yml    │  (run once / on Dockerfile change)
             │  builds & pushes to    │
             │  GHCR:                 │
             │   rdgen-linux-builder  │
             │   rdgen-android-builder│
             │   rdgen-windows-builder│
             └───────────┬────────────┘
                         │ pull
   web /batch  ─────►  docker-generator.yml  ─────►  docker run <image>
   web single  ─────►  (matrix: linux/android/windows)      │
   rdbuild.sh  ──────────────────────────────────────►──────┘
                                                             │
                                              scripts/build-<platform>.{sh,ps1}
                                              → customise → compile → package
                                              → upload artifacts back to rdgen
```

The toolchain (Rust, Flutter, vcpkg, NDK, MSVC, …) lives **in the image**, built
once and cached. A build job only pulls the image, drops in a `build.json`, and
runs it.

### Files

| Path | Purpose |
|------|---------|
| `docker/linux-builder.Dockerfile`   | Linux toolchain (Ubuntu 18.04 base for old-glibc compatibility) |
| `docker/android-builder.Dockerfile` | Android toolchain (SDK + NDK + Flutter) |
| `docker/windows-builder.Dockerfile` | Windows toolchain (MSVC + Windows SDK + Flutter); Windows container |
| `scripts/lib/common.sh` | shared helpers: config loading, checkout, bridge codegen, upload |
| `scripts/customize.sh`  | all source-level whitelabelling (one copy for every platform) |
| `scripts/build-linux.sh`, `build-android.sh`, `build-windows.ps1` | per-platform build + package |
| `scripts/rdbuild.sh`    | local orchestrator (`docker run` wrapper, multi-platform) |
| `scripts/config.example.json` | annotated example `build.json` |
| `.github/workflows/builder-images.yml` | build & push the images to GHCR |
| `.github/workflows/docker-generator.yml` | run containerised builds in CI |

---

## One-time setup: publish the builder images

The build workflows pull images from GHCR, so build and push them once (and
again whenever a Dockerfile or a build script changes — the `push` trigger does
this automatically for `docker/**` and `scripts/**` on `master`).

Manually, from the Actions tab, run **Build Docker Builder Images** and pick the
platforms:

- `linux,android` build on normal Ubuntu runners.
- `windows` needs a `windows-2022` runner and produces a ~25 GB image; expect a
  long first build.

Images are published as:

```
ghcr.io/<owner>/rdgen-linux-builder:latest
ghcr.io/<owner>/rdgen-android-builder:latest
ghcr.io/<owner>/rdgen-windows-builder:latest
```

Make sure the packages are readable by the Actions workflows (GHCR packages
inherit repo visibility; for private repos the default `GITHUB_TOKEN` already
has access).

---

## Building from the web app (batch scheduler)

1. Open **`/batch`** (there's a button on the main builder page:
   *“Schedule builds for multiple platforms at once”*).
2. Tick the platforms you want (Linux / Windows / Android).
3. Fill in the client configuration once — it applies to every platform.
4. **Schedule builds.** Each platform is dispatched as its own
   `docker-generator.yml` run, and you land on a live dashboard that polls until
   every build finishes, with a build-log link and download links per platform.

Under the hood each platform gets its own `uuid`, so the existing per-run status
tracking (`/updategh`, `/check_for_file`) works unchanged.

### Settings

`rdgen/settings.py` reads one extra environment variable:

| Env var | Default | Meaning |
|---------|---------|---------|
| `BUILDER_IMAGE_TAG` | `latest` | Which builder-image tag `docker-generator.yml` pulls |

The web app also needs the variables it already used (`GHUSER`, `GHBEARER`,
`GHBRANCH`, `REPONAME`, `GENURL`, `ZIP_PASSWORD`, …) — see `setup.md`.

---

## Building locally with `rdbuild.sh` (recommended for a public fork)

No GitHub, no GHCR, no Actions — just Docker on your own machine. This is the
right approach when the repo is a **public fork you can't make private**: you
turn CI off entirely (see below) and build everything locally instead.

`rdbuild.sh` is **local-first**: it builds the builder image on your machine the
first time and reuses it afterwards. Nothing is pulled from a registry unless
you explicitly ask for one.

```bash
# From a config file, two platforms in one go:
scripts/rdbuild.sh --config my-build.json --platforms linux,android

# Override individual fields on the command line (any build.json key works):
scripts/rdbuild.sh --platforms linux \
    --appname "Acme Remote" --filename acme-remote \
    --server rs.acme.com --apiServer https://api.acme.com

# Rebuild the builder image (e.g. after changing a Dockerfile):
scripts/rdbuild.sh --config my-build.json --platforms linux --rebuild-image

# Advanced: opt in to a prebuilt image from a registry instead of local build:
scripts/rdbuild.sh --registry ghcr.io/yourname --platforms linux
```

Artifacts land in `./output/<platform>/`. The first Linux/Android image build
takes a while (it compiles the toolchain once); subsequent runs are fast.

### On Windows with Docker Desktop / WSL2

- **Linux and Android** build fine under Docker Desktop's WSL2 backend — they are
  Linux containers. Run the commands above from a WSL/PowerShell shell.
- **Windows** (`.exe`/`.msi`) is a *Windows container* and **cannot** run under
  WSL2 (that's a Linux VM). To build it locally you must switch Docker Desktop to
  "Windows containers" mode on a Windows host; the image is large (~25 GB). For
  most people it's easier to build Linux/Android locally and skip the Windows
  target, or run just that one on a Windows machine.

---

## Running the web app in local mode (no GitHub)

The Django app can execute builds on the machine it runs on instead of
dispatching GitHub Actions. Set one environment variable:

```bash
export BUILD_ENGINE=local        # 'github' (default) or 'local'
```

With `BUILD_ENGINE=local`, the **single builder** and the **batch scheduler**
both run `scripts/rdbuild.sh` locally. The existing waiting page and batch
dashboard work unchanged — status is tracked in the database and updated as the
build progresses (`queued → building → success/failure`), and finished
artifacts are served from the same `/download` links as before. A plain-text
build log is available at `/local_log?uuid=<uuid>`.

Relevant settings (all env vars):

| Env var | Default | Meaning |
|---------|---------|---------|
| `BUILD_ENGINE` | `github` | `local` runs builds on this machine |
| `RDGEN_REPO_ROOT` | project dir | where `scripts/` lives and artifacts are written |
| `LOCAL_BUILD_PLATFORMS` | `linux,android,windows` | platforms the local engine may build |

Notes and limits of local mode:
- The machine running the app needs **Docker** (for Linux/Android). On Windows,
  if the app runs on the same host, it uses the **native** Windows build
  (below) instead of Docker.
- Custom **icon/logo PNGs** are fetched by the build over HTTP from the app.
  That works when the build can reach the app's URL; a Docker container on the
  same host usually can't reach `localhost`, so custom PNGs may be skipped in
  local Docker builds (the client still builds fine, just with default icons).
- Builds run in a background thread. Use one worker per build-in-flight if you
  run under gunicorn and expect concurrency.

---

## Native Windows builds (no Docker) — for a Hyper-V VM

Windows containers are heavy and can't run under WSL2, so for Windows the
simplest local path is a **native build inside a Windows VM** (e.g. Hyper-V).
Two scripts under `scripts/windows/`:

```powershell
# 1) One-time: install the toolchain (MSVC, Rust, Flutter, LLVM, vcpkg, ...).
#    Run elevated. -Persist writes the env vars machine-wide.
powershell -ExecutionPolicy Bypass -File scripts\windows\setup-toolchain.ps1 -Persist

# 2) Build from a config (open a fresh shell after step 1):
powershell -ExecutionPolicy Bypass -File scripts\windows\build-windows-native.ps1 `
    -Config .\build.json -Output .\output

#    Or do both at once the first time:
powershell -ExecutionPolicy Bypass -File scripts\windows\build-windows-native.ps1 `
    -Config .\build.json -Setup
```

`build-windows-native.ps1` reuses the same `scripts/build-windows.ps1` logic as
the container, but that script now **discovers the toolchain on PATH** (MSBuild
via vswhere, nuget, git-bash, vcpkg), so it runs identically in a container or
on a bare VM. Artifacts (`<filename>.exe`, `<filename>.msi`) land in `-Output`.

If the Django app runs **inside** that same Windows VM with
`BUILD_ENGINE=local`, it will call the native Windows build automatically for
`windows` targets (no Docker needed).

---

## Turning GitHub Actions OFF completely (public fork)

If you only ever build locally, you can guarantee that **no CI ever runs** on
your fork — nobody can trigger a build, burn your Actions minutes, or produce
downloadable artifacts through a workflow run. Two layers:

### 1. Disable Actions in the repository settings (the real guarantee)

This is a one-click, owner-only switch that no other user can bypass:

> **Settings → Actions → General → Actions permissions → "Disable actions" → Save**

With Actions disabled, *every* workflow in the repo (including the legacy
`generator-*.yml` and `docker-build.yml`) is inert. This is the definitive way
to lock CI on a public fork.

### 2. The built-in kill-switch (defense in depth)

Even if Actions is left enabled, the container build workflows
(`docker-generator.yml`, `builder-images.yml`) refuse to do anything unless the
repository variable **`RDGEN_ENABLE_CI`** is set to `true`. It is **unset by
default**, so these workflows are no-ops out of the box.

To *use* CI builds later, set the variable
(Settings → Secrets and variables → Actions → Variables → New variable:
`RDGEN_ENABLE_CI = true`). To keep CI off, just never set it.

> Note: with Actions disabled, the Django web app's "Generate" / batch buttons
> stop working, because they dispatch GitHub workflows. Local `rdbuild.sh` is
> the intended path in that setup.

### `build.json`

Copy `scripts/config.example.json` and edit. Every key becomes an environment
variable inside the container; the important ones:

| Key | Meaning |
|-----|---------|
| `platform` | `linux` / `windows` / `android` (set automatically by `rdbuild.sh`) |
| `version` | RustDesk tag to build, e.g. `1.4.9`, or `master` |
| `appname` | custom application name (whitelabel) |
| `filename` | output file base name |
| `compname` | company name shown in the UI |
| `server`, `key`, `apiServer` | your RustDesk server + public key |
| `androidappid` | Android application id |
| `urlLink`, `downloadLink` | custom homepage / update URLs |
| `custom` | base64 custom settings blob (as produced by the web form) |
| `delayFix`, `xOffline`, `hidecm`, `removeNewVersionNotif` | feature toggles |
| `android_abis` | comma list, default `arm64-v8a,armeabi-v7a,x86_64` |
| `upload_url`, `status_url`, `token`, `uuid` | optional: POST artifacts/status back to a running rdgen server |

If `upload_url` is empty the artifacts are simply left in the output directory —
which is exactly what you want for a local build.

---

## How customisation stays in sync

Previously each `generator-*.yml` workflow carried its own copy of the “change
app name / change url / allow custom.txt / hide cm / …” steps. That logic now
lives once in `scripts/customize.sh` (`customize_common` + `customize_android`),
so a change to the whitelabelling applies to every platform at once. The build
scripts source it and call it after checkout.

The Flutter dropdown patch and the RustDesk-specific patches
(`allowCustom.py`, `xoffline.diff`, `hidecm.diff`, …) are baked into the images
from `.github/patches/`, with a network fallback if a patch is missing.

---

## Troubleshooting

- **“Image not available, building locally”** from `rdbuild.sh` — GHCR doesn't
  have the image yet (or it's private and you're not logged in). Run
  `docker login ghcr.io`, or pass `--build-image`.
- **Windows build can't find MSBuild / nuget** — the Windows image must be built
  and run on a Windows host; it won't run under Linux Docker.
- **A build fails only for one platform in a batch** — the others still complete;
  the failed job shows its status and a link to the GitHub build log.
- **macOS/iOS** — not supported in Docker by design; use `generator-macos.yml`.
