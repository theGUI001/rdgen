# RDGen, a RustDesk client generator to use with your self-hosted RustDesk server

The client generator is currently hosted [here](https://rdgen.crayoneater.org).
If you would like to host the generator yourself, see [here](setup.md)

## Features

- Embed server and key into client
- Custom app name
- Custom icon/logo
- Set default settings for the client
- Support for rustdesk advanced settings (https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/)

## Docker-based builds & multi-platform batch scheduling

You can now build custom clients **inside Docker containers** instead of setting
up the whole toolchain on each run, and **queue builds for several platforms at
once**:

- **Batch scheduler:** open `/batch` (or the *“Schedule builds for multiple
  platforms at once”* button on the builder page), pick Linux / Windows /
  Android, configure once, and get a live dashboard for all of them.
- **Local builds:** `scripts/rdbuild.sh --config build.json --platforms linux,android`
  builds with plain `docker run`, no GitHub needed.
- **Local web app:** set `BUILD_ENGINE=local` and the site runs builds on its own
  machine instead of dispatching GitHub Actions (great for a public fork with
  Actions disabled).
- **Native Windows (no Docker):** `scripts/windows/` builds `.exe`/`.msi` directly
  in a Windows/Hyper-V VM.
- **CI:** `docker-generator.yml` runs the containerised build on GitHub Actions;
  `builder-images.yml` publishes the toolchain images to GHCR.

Linux, Windows and Android are supported in Docker. macOS/iOS still require a
macOS runner (`generator-macos.yml`). Full details in
[`docs/BUILDS.md`](docs/BUILDS.md).

## Generate RustDesk clients from command line instead of using a web browser

Save your configuration from the rdgen web interface, or generate your own, then use that json file with [@AlekseyLapunov's rdgen-cli](https://github.com/AlekseyLapunov/rdgen-cli) to build from the command line on Windows, Linux, or MacOS like this: `python rdgen-cli -f my_config.json --set-version 1.4.5 --set-platform windows -s https://rdgen.crayoneater.org`

## Notes

- Icons should be square (256x256 recommended)
- Avoid special characters or non-English characters in app name and file name
- Build time is currently 30 - 45 minutes

