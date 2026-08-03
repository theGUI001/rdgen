# escape=`
# RustDesk Windows build toolchain, as a Windows container.
#
# This image only builds and runs on a Windows host with Windows containers
# enabled (on GitHub Actions: the `windows-2022` runner). It is large (~25 GB)
# because it carries the MSVC toolchain, the Windows SDK and Flutter, so build
# it once, push it to GHCR and reuse it. See docker/README.md.
ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2022
FROM ${BASE_IMAGE}

ARG RUST_VERSION=1.75
ARG FLUTTER_VERSION=3.24.5
ARG LLVM_VERSION=15.0.6
ARG VCPKG_COMMIT_ID=120deac3062162151622ca4860575a33844ba10b
ARG PYTHON_VERSION=3.11.9

SHELL ["powershell", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

ENV CARGO_HOME=C:\cargo `
    RUSTUP_HOME=C:\rustup `
    FLUTTER_HOME=C:\flutter `
    VCPKG_ROOT=C:\vcpkg `
    VCPKG_DEFAULT_BINARY_CACHE=C:\vcpkg-cache `
    LIBCLANG_PATH=C:\Program` Files\LLVM\bin

# Visual Studio Build Tools: MSVC x64, the Windows 10 SDK and the ATL/MFC bits
# RustDesk's msi project needs. Flutter's windows desktop build detects this
# through vswhere.
RUN Invoke-WebRequest -Uri https://aka.ms/vs/17/release/vs_buildtools.exe -OutFile C:\vs_buildtools.exe; `
    Start-Process -FilePath C:\vs_buildtools.exe -Wait -NoNewWindow -ArgumentList `
      '--quiet','--wait','--norestart','--nocache', `
      '--installPath','C:\BuildTools', `
      '--add','Microsoft.VisualStudio.Workload.VCTools', `
      '--add','Microsoft.VisualStudio.Component.VC.Tools.x86.x64', `
      '--add','Microsoft.VisualStudio.Component.Windows11SDK.22621', `
      '--add','Microsoft.VisualStudio.Component.VC.ATL', `
      '--add','Microsoft.VisualStudio.Component.VC.ATLMFC', `
      '--add','Microsoft.VisualStudio.Component.VC.CMake.Project', `
      '--includeRecommended'; `
    Remove-Item C:\vs_buildtools.exe -Force

# Git, 7zip, nuget, Python.
RUN Invoke-WebRequest -Uri https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/MinGit-2.45.2-64-bit.zip -OutFile C:\mingit.zip; `
    Expand-Archive C:\mingit.zip -DestinationPath C:\mingit; `
    Remove-Item C:\mingit.zip -Force; `
    Invoke-WebRequest -Uri https://www.7-zip.org/a/7z2301-x64.exe -OutFile C:\7z.exe; `
    Start-Process -FilePath C:\7z.exe -Wait -ArgumentList '/S'; `
    Remove-Item C:\7z.exe -Force; `
    New-Item -ItemType Directory -Force -Path C:\tools | Out-Null; `
    Invoke-WebRequest -Uri https://dist.nuget.org/win-x86-commandline/latest/nuget.exe -OutFile C:\tools\nuget.exe; `
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$env:PYTHON_VERSION/python-$env:PYTHON_VERSION-amd64.exe" -OutFile C:\python.exe; `
    Start-Process -FilePath C:\python.exe -Wait -ArgumentList '/quiet','InstallAllUsers=1','PrependPath=1','Include_pip=1'; `
    Remove-Item C:\python.exe -Force

ENV PATH="C:\mingit\cmd;C:\tools;C:\Program Files\7-Zip;C:\cargo\bin;C:\flutter\bin;C:\Program Files\LLVM\bin;C:\Python311;C:\Python311\Scripts;C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0"

RUN Invoke-WebRequest -Uri "https://github.com/llvm/llvm-project/releases/download/llvmorg-$env:LLVM_VERSION/LLVM-$env:LLVM_VERSION-win64.exe" -OutFile C:\llvm.exe; `
    Start-Process -FilePath C:\llvm.exe -Wait -ArgumentList '/S'; `
    Remove-Item C:\llvm.exe -Force

RUN Invoke-WebRequest -Uri https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe -OutFile C:\rustup-init.exe; `
    Start-Process -FilePath C:\rustup-init.exe -Wait -NoNewWindow -ArgumentList `
      '-y','--default-toolchain',$env:RUST_VERSION,'--default-host','x86_64-pc-windows-msvc','--profile','minimal','--component','rustfmt'; `
    Remove-Item C:\rustup-init.exe -Force

RUN Invoke-WebRequest -Uri "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$env:FLUTTER_VERSION-stable.zip" -OutFile C:\flutter.zip; `
    Expand-Archive C:\flutter.zip -DestinationPath C:\; `
    Remove-Item C:\flutter.zip -Force; `
    git config --global --add safe.directory '*'; `
    flutter config --no-analytics; `
    flutter precache --windows

# RustDesk ships against a patched Flutter engine on Windows.
RUN Invoke-WebRequest -Uri https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip -OutFile C:\engine.zip; `
    Expand-Archive C:\engine.zip -DestinationPath C:\engine; `
    Copy-Item C:\engine\* -Destination C:\flutter\bin\cache\artifacts\engine\windows-x64-release\ -Recurse -Force; `
    Remove-Item C:\engine.zip,C:\engine -Recurse -Force

COPY .github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff C:/patches/
RUN if ($env:FLUTTER_VERSION -eq '3.24.5') { `
      cd C:\flutter; git apply C:\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff; `
      if ($LASTEXITCODE -ne 0) { Write-Host 'flutter patch did not apply, continuing' } `
    }

RUN git clone https://github.com/microsoft/vcpkg C:\vcpkg; `
    cd C:\vcpkg; git checkout $env:VCPKG_COMMIT_ID; `
    C:\vcpkg\bootstrap-vcpkg.bat -disableMetrics; `
    New-Item -ItemType Directory -Force -Path C:\vcpkg-cache | Out-Null

COPY scripts C:/rdgen/scripts

WORKDIR C:/work
ENTRYPOINT ["powershell", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:/rdgen/scripts/build-windows.ps1"]
