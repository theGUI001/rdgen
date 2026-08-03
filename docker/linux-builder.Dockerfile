# RustDesk Linux build toolchain.
#
# Ubuntu 18.04 is deliberate: it is the same base the upstream rdgen workflow
# compiles in (via run-on-arch-action), so the resulting .deb/.rpm keep working
# on distros with an old glibc. Override with --build-arg BASE_IMAGE=... if you
# only care about modern targets.
ARG BASE_IMAGE=ubuntu:18.04
FROM ${BASE_IMAGE}

ARG RUST_VERSION=1.75
ARG FLUTTER_VERSION=3.24.5
ARG VCPKG_COMMIT_ID=120deac3062162151622ca4860575a33844ba10b
ARG FLUTTER_RUST_BRIDGE_VERSION=1.80.1
ARG CARGO_EXPAND_VERSION=1.0.95
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    VCPKG_ROOT=/opt/artifacts/vcpkg \
    VCPKG_DEFAULT_BINARY_CACHE=/opt/artifacts/vcpkg-cache \
    CARGO_HOME=/opt/cargo \
    RUSTUP_HOME=/opt/rustup \
    FLUTTER_HOME=/opt/flutter \
    RD_RUST_VERSION=${RUST_VERSION} \
    RD_FLUTTER_VERSION=${FLUTTER_VERSION}
ENV PATH=${CARGO_HOME}/bin:${FLUTTER_HOME}/bin:${PATH}

# 18.04 is EOL, its packages only live on old-releases now.
RUN if grep -q "18.04" /etc/os-release; then \
      sed -i -e 's|http://archive.ubuntu.com|http://old-releases.ubuntu.com|g' \
             -e 's|http://security.ubuntu.com|http://old-releases.ubuntu.com|g' \
             /etc/apt/sources.list; \
    fi

RUN apt-get update -y && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      curl \
      file \
      gcc \
      g++ \
      git \
      imagemagick \
      libasound2-dev \
      libayatana-appindicator3-dev \
      libclang-10-dev \
      libgstreamer1.0-dev \
      libgstreamer-plugins-base1.0-dev \
      libgtk-3-dev \
      libpam0g-dev \
      libpulse-dev \
      libssl-dev \
      libva-dev \
      libxcb-randr0-dev \
      libxcb-shape0-dev \
      libxcb-xfixes0-dev \
      libxdo-dev \
      libxfixes-dev \
      llvm-10-dev \
      nasm \
      ninja-build \
      pkg-config \
      python3 \
      python3-pip \
      rpm \
      rsync \
      tree \
      unzip \
      wget \
      xz-utils \
      zip \
    && apt-get remove -y libopus-dev || true \
    && rm -rf /var/lib/apt/lists/*

# Rust. rustup, not the tarball dance the old workflow needed under qemu.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal --component rustfmt \
    && chmod -R a+rwX "${CARGO_HOME}" "${RUSTUP_HOME}"

# flutter_rust_bridge codegen, so the container can generate the bridge itself
# instead of depending on a separate CI job + artifact upload.
RUN cargo install cargo-expand --version "${CARGO_EXPAND_VERSION}" --locked \
    && cargo install flutter_rust_bridge_codegen --version "${FLUTTER_RUST_BRIDGE_VERSION}" --features uuid --locked \
    && rm -rf "${CARGO_HOME}/registry" "${CARGO_HOME}/git"

# Flutter SDK.
RUN mkdir -p /opt \
    && wget -q -O /tmp/flutter.tar.xz \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && tar xf /tmp/flutter.tar.xz -C /opt \
    && rm /tmp/flutter.tar.xz \
    && git config --global --add safe.directory '*' \
    && flutter config --no-analytics \
    && flutter precache --linux \
    && chmod -R a+rwX "${FLUTTER_HOME}"

# The dropdown_menu patch rdgen applies to Flutter 3.24.x. Baked in here so the
# build itself does not have to reach for the patch at runtime.
COPY .github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff /opt/patches/
RUN if [ "${FLUTTER_VERSION}" = "3.24.5" ]; then \
      cd "${FLUTTER_HOME}" && git apply /opt/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff || \
        echo "flutter patch did not apply, continuing"; \
    fi

# vcpkg, pinned to the commit rdgen builds against, with the RustDesk manifest
# pre-installed so the binary cache is already warm inside the image.
RUN mkdir -p /opt/artifacts "${VCPKG_DEFAULT_BINARY_CACHE}" \
    && git clone https://github.com/microsoft/vcpkg "${VCPKG_ROOT}" \
    && git -C "${VCPKG_ROOT}" checkout "${VCPKG_COMMIT_ID}" \
    && "${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics

RUN set -eux; \
    triplet="x64-linux"; \
    if [ "${TARGETARCH}" = "arm64" ]; then triplet="arm64-linux"; fi; \
    echo "${triplet}" > /opt/artifacts/vcpkg-triplet; \
    mkdir -p /tmp/manifest; \
    cd /tmp/manifest; \
    wget -q -O vcpkg.json https://raw.githubusercontent.com/rustdesk/rustdesk/master/vcpkg.json || true; \
    if [ -s vcpkg.json ]; then \
      "${VCPKG_ROOT}/vcpkg" install --triplet "${triplet}" --x-install-root="${VCPKG_ROOT}/installed" || \
        echo "vcpkg warm-up failed; the build will install what is missing"; \
    fi; \
    rm -rf /tmp/manifest "${VCPKG_ROOT}/buildtrees" "${VCPKG_ROOT}/downloads"; \
    chmod -R a+rwX /opt/artifacts

RUN pip3 install --no-cache-dir --upgrade "pip<22" \
    && pip3 install --no-cache-dir requests || true

COPY scripts /opt/rdgen/scripts
RUN chmod -R a+rx /opt/rdgen/scripts

WORKDIR /work
ENTRYPOINT ["/opt/rdgen/scripts/build-linux.sh"]
