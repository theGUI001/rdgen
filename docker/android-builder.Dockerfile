# RustDesk Android build toolchain.
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ARG RUST_VERSION=1.75
ARG FLUTTER_VERSION=3.24.5
ARG NDK_VERSION=r28c
ARG CARGO_NDK_VERSION=3.1.2
ARG VCPKG_COMMIT_ID=120deac3062162151622ca4860575a33844ba10b
ARG FLUTTER_RUST_BRIDGE_VERSION=1.80.1
ARG CARGO_EXPAND_VERSION=1.0.95
ARG ANDROID_CMDLINE_TOOLS=11076708
ARG ANDROID_BUILD_TOOLS=34.0.0
ARG ANDROID_PLATFORM=android-34

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    VCPKG_ROOT=/opt/artifacts/vcpkg \
    VCPKG_DEFAULT_BINARY_CACHE=/opt/artifacts/vcpkg-cache \
    CARGO_HOME=/opt/cargo \
    RUSTUP_HOME=/opt/rustup \
    FLUTTER_HOME=/opt/flutter \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_NDK_HOME=/opt/android-ndk \
    ANDROID_NDK_ROOT=/opt/android-ndk \
    RD_RUST_VERSION=${RUST_VERSION} \
    RD_FLUTTER_VERSION=${FLUTTER_VERSION}
ENV PATH=${CARGO_HOME}/bin:${FLUTTER_HOME}/bin:${JAVA_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_NDK_HOME}:${PATH}

RUN apt-get update -y && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      curl \
      file \
      gcc-multilib \
      g++-multilib \
      git \
      imagemagick \
      libasound2-dev \
      libayatana-appindicator3-dev \
      libc6-dev \
      libclang-dev \
      libgstreamer1.0-dev \
      libgstreamer-plugins-base1.0-dev \
      libgtk-3-dev \
      libpam0g-dev \
      libpulse-dev \
      libunwind-dev \
      libva-dev \
      libvdpau-dev \
      libxcb-randr0-dev \
      libxcb-shape0-dev \
      libxcb-xfixes0-dev \
      libxdo-dev \
      libxfixes-dev \
      llvm-dev \
      nasm \
      ninja-build \
      openjdk-17-jdk-headless \
      pkg-config \
      potrace \
      python3 \
      python3-pip \
      tree \
      unzip \
      wget \
      xz-utils \
      zip \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal --component rustfmt \
    && rustup target add \
        aarch64-linux-android \
        armv7-linux-androideabi \
        x86_64-linux-android \
    && cargo install cargo-ndk --version "${CARGO_NDK_VERSION}" --locked \
    && cargo install cargo-expand --version "${CARGO_EXPAND_VERSION}" --locked \
    && cargo install flutter_rust_bridge_codegen --version "${FLUTTER_RUST_BRIDGE_VERSION}" --features uuid --locked \
    && rm -rf "${CARGO_HOME}/registry" "${CARGO_HOME}/git" \
    && chmod -R a+rwX "${CARGO_HOME}" "${RUSTUP_HOME}"

# Android SDK (command line tools + platform + build tools) and NDK.
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" \
    && wget -q -O /tmp/cmdline-tools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
    && unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_HOME}/cmdline-tools" \
    && mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip \
    && yes | sdkmanager --licenses > /dev/null \
    && sdkmanager "platform-tools" "platforms;${ANDROID_PLATFORM}" "build-tools;${ANDROID_BUILD_TOOLS}" > /dev/null \
    && chmod -R a+rwX "${ANDROID_HOME}"

RUN wget -q -O /tmp/ndk.zip "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" \
    && unzip -q /tmp/ndk.zip -d /opt \
    && mv "/opt/android-ndk-${NDK_VERSION}" "${ANDROID_NDK_HOME}" \
    && rm /tmp/ndk.zip

RUN wget -q -O /tmp/flutter.tar.xz \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && tar xf /tmp/flutter.tar.xz -C /opt \
    && rm /tmp/flutter.tar.xz \
    && git config --global --add safe.directory '*' \
    && flutter config --no-analytics --android-sdk "${ANDROID_HOME}" \
    && flutter precache --android \
    && chmod -R a+rwX "${FLUTTER_HOME}"

COPY .github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff /opt/patches/
RUN if [ "${FLUTTER_VERSION}" = "3.24.5" ]; then \
      cd "${FLUTTER_HOME}" && git apply /opt/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff || \
        echo "flutter patch did not apply, continuing"; \
    fi

# vcpkg for the Android native deps. The per-ABI install has to happen at build
# time (it runs rustdesk's own flutter/build_android_deps.sh), so here we only
# bootstrap and keep a writable binary cache.
RUN mkdir -p /opt/artifacts "${VCPKG_DEFAULT_BINARY_CACHE}" \
    && git clone https://github.com/microsoft/vcpkg "${VCPKG_ROOT}" \
    && git -C "${VCPKG_ROOT}" checkout "${VCPKG_COMMIT_ID}" \
    && "${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics \
    && chmod -R a+rwX /opt/artifacts

RUN pip3 install --no-cache-dir requests || true

COPY scripts /opt/rdgen/scripts
RUN chmod -R a+rx /opt/rdgen/scripts

WORKDIR /work
ENTRYPOINT ["/opt/rdgen/scripts/build-android.sh"]
