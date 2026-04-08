# =============================================================================
# Multi-stage Docker image — PickupWinder cross-compile environment.
#
# Stage 1 (builder):  compiles the PRU toolchain (pru-unknown-elf-gcc) via
#                     crosstool-ng, running as a non-root user so ct-ng is happy.
# Stage 2 (runtime):  minimal Debian 12 image with PRU + ARM gnueabihf toolchains.
#
# Build:
#   docker build \
#     --build-arg BUILDER_UID=$(id -u) \
#     --build-arg BUILDER_GID=$(id -g) \
#     -t antnic/bbb-crosscompile:debian12 .
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — build PRU toolchain via crosstool-ng
# -----------------------------------------------------------------------------
FROM antnic/crosstools-ng:debian12-1.28 AS builder

ARG BUILDER_UID=1000
ARG BUILDER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

# Create a non-root builder user; ct-ng refuses to run as root.
RUN groupadd -g "${BUILDER_GID}" builder \
    && useradd -m -u "${BUILDER_UID}" -g "${BUILDER_GID}" builder \
    && mkdir -p /home/builder/toolchain-build /home/builder/x-tools \
    && chown -R builder:builder /home/builder/toolchain-build /home/builder/x-tools

WORKDIR /home/builder/toolchain-build

COPY config /home/builder/toolchain-build/config

# Build the PRU toolchain.
# ct-ng installs the result to /home/builder/x-tools/ (CT_PREFIX default for
# the non-root user).  A custom .config must be provided in config/pru/.config.
#
# Output is streamed live to stdout (visible with --progress=plain) and also
# written to /home/builder/ct-ng-build.log inside the builder stage.
# On failure the last 100 lines are repeated so the error is clearly visible.
#
# ct-ng sample name on version 1.28: 'pru'  (not 'pru-unknown-elf')
RUN chown -R builder:builder /home/builder/toolchain-build \
    && if [ -f /home/builder/toolchain-build/config/pru/.config ]; then \
         runuser -u builder -- bash -lc \
           'cp /home/builder/toolchain-build/config/pru/.config . \
            && ct-ng build 2>&1 | tee /home/builder/ct-ng-build.log \
            || { echo "=== ct-ng build FAILED — last 100 lines ==="; \
                 tail -100 /home/builder/ct-ng-build.log; exit 1; }'; \
       else \
         runuser -u builder -- bash -lc \
           'ct-ng pru 2>/dev/null || true; \
            if [ -f .config ]; then \
              ct-ng build 2>&1 | tee /home/builder/ct-ng-build.log \
              || { echo "=== ct-ng build FAILED — last 100 lines ==="; \
                   tail -100 /home/builder/ct-ng-build.log; exit 1; }; \
            else \
              echo "WARNING: no PRU toolchain config found — skipping toolchain build."; \
            fi'; \
       fi

# ARM toolchain — uncomment and provide config/arm/.config to build a custom
# arm-linux-gnueabihf toolchain instead of relying on the Debian package:
# RUN mkdir -p /home/builder/toolchain-build/arm \
#     && chown builder:builder /home/builder/toolchain-build/arm \
#     && cd /home/builder/toolchain-build/arm \
#     && runuser -u builder -- bash -lc \
#          'cp /home/builder/toolchain-build/config/arm/.config . && ct-ng build'

# -----------------------------------------------------------------------------
# Stage 2 — runtime image used to compile the PickupWinder project
# -----------------------------------------------------------------------------
FROM debian:12-slim AS runtime

LABEL org.opencontainers.image.title="PickupWinder cross-compile environment" \
      org.opencontainers.image.description="PRU (pru-unknown-elf) + ARM gnueabihf cross-compilers for BeagleBone Black" \
      org.opencontainers.image.source="https://github.com/an-nix/bbb-crosscompile" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# TOOLCHAIN_DIR is read by the project Makefiles to locate pru-unknown-elf-gcc.
ENV TOOLCHAIN_DIR=/usr/local/x-tools

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        g++ \
        gcc-arm-linux-gnueabihf \
        g++-arm-linux-gnueabihf \
        make \
        gawk \
        python3 \
        python3-pip \
        device-tree-compiler \
        file \
    && rm -rf /var/lib/apt/lists/*

# Copy the PRU toolchain compiled in the builder stage.
COPY --from=builder /home/builder/x-tools /usr/local/x-tools

# Ensure all toolchain files are readable and executable for any user.
# This is required when the container is run with --user <uid>:<gid>:
# files copied via COPY --from are owned by root and may lack o+rx.
# chmod a+rX: sets read for all, and execute only on files already executable
# (i.e. binaries), not on plain data files.
RUN chmod -R a+rX /usr/local/x-tools

# Symlink PRU toolchain binaries into /usr/local/bin so they are found by
# both interactive shells and non-login make invocations without modifying PATH.
RUN find /usr/local/x-tools -maxdepth 5 -name 'pru-unknown-elf-*' -type f \
    | xargs -r -I{} ln -sf {} /usr/local/bin/

ENV PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

WORKDIR /workspace
CMD ["bash"]
