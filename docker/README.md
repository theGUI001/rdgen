# Builder images

Docker images carrying the full RustDesk build toolchain, so a custom-client
build only has to pull an image and run it. See [`../docs/BUILDS.md`](../docs/BUILDS.md)
for the full picture.

| Dockerfile | Host needed | Produces |
|------------|-------------|----------|
| `linux-builder.Dockerfile`   | Linux (or any Docker) | `.deb`, `.rpm` |
| `android-builder.Dockerfile` | Linux (or any Docker) | `.apk` (per ABI) |
| `windows-builder.Dockerfile` | **Windows host, Windows containers** | `.exe`, `.msi` |

Build locally:

```bash
docker build -f docker/linux-builder.Dockerfile   -t rdgen-linux-builder   .
docker build -f docker/android-builder.Dockerfile -t rdgen-android-builder .
# Windows, on a Windows host only:
docker build -f docker/windows-builder.Dockerfile -t rdgen-windows-builder .
```

Then run a build (config schema in `../scripts/config.example.json`):

```bash
docker run --rm \
  -v "$PWD/build.json:/work/build.json:ro" \
  -v "$PWD/output:/work/output" \
  rdgen-linux-builder
```

Or let `../scripts/rdbuild.sh` handle pulling/building and multi-platform
scheduling for you.

## Notable build args

Each Dockerfile pins the versions rdgen builds against (`RUST_VERSION`,
`FLUTTER_VERSION`, `VCPKG_COMMIT_ID`, `NDK_VERSION`, …). Override with
`--build-arg` if you need a different toolchain, e.g.:

```bash
docker build -f docker/linux-builder.Dockerfile \
  --build-arg FLUTTER_VERSION=3.24.5 \
  --build-arg BASE_IMAGE=ubuntu:22.04 \
  -t rdgen-linux-builder .
```

The Linux image defaults to an Ubuntu 18.04 base on purpose: it matches what the
upstream workflow compiled against, keeping the `.deb`/`.rpm` usable on distros
with an older glibc. Use `--build-arg BASE_IMAGE=ubuntu:22.04` if you only target
modern systems and want a faster build.
