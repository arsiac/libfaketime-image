# syntax=docker/dockerfile:1

# One artifact per baseline in docker/build-base.lock, copied into every
# compatible carrier in docker/bases.lock.
ARG BASE_TAG=11-slim
ARG GLIBC=2.31
ARG APT_ARCHIVE=1
ARG FINAL_BASE=11-slim

# Depends only on the baseline, so BuildKit reuses it across its carriers.
FROM debian:${BASE_TAG} AS toolchain

# ARGs declared before the first FROM are not visible in stages; the ones the
# RUN uses are re-declared here.
ARG APT_ARCHIVE
ARG GLIBC

# For archived releases: switch sources to archive.debian.org, drop
# -updates/-backports (not always archived), and allow the unsigned archive.
# The published glibc is asserted against the toolchain.
RUN set -eux; \
    libc="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"; \
    if [ "$libc" != "${GLIBC}" ]; then \
      echo "toolchain reports glibc $libc, docker/build-base.lock says ${GLIBC}" >&2; \
      exit 1; \
    fi; \
    if [ "${APT_ARCHIVE}" = "1" ]; then \
      sed -i \
        -e 's|deb.debian.org/debian|archive.debian.org/debian|g' \
        -e 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' \
        -e '/-updates/d' \
        -e '/-backports/d' \
        /etc/apt/sources.list; \
      apt-get -o Acquire::Check-Valid-Until=false \
              -o Acquire::AllowInsecureRepositories=true update; \
      apt-get install -y --allow-unauthenticated --no-install-recommends \
              build-essential ca-certificates curl; \
    else \
      apt-get update; \
      apt-get install -y --no-install-recommends build-essential ca-certificates curl; \
    fi; \
    rm -rf /var/lib/apt/lists/*


FROM toolchain AS build

ARG LIBFAKETIME_VERSION
ARG LIBFAKETIME_URL
ARG LIBFAKETIME_SHA256
ARG EXTRA_CFLAGS=""
ARG INSTALL_PREFIX=/usr/local

WORKDIR /src

RUN set -eux; \
    case "${LIBFAKETIME_SHA256}" in \
      ""|TODO*) echo "libfaketime ${LIBFAKETIME_VERSION} is not pinned; run scripts/update-lock.sh" >&2; exit 1 ;; \
    esac; \
    curl --retry 3 --retry-delay 2 -fsSL -o libfaketime.tar.gz "${LIBFAKETIME_URL}"; \
    echo "${LIBFAKETIME_SHA256}  libfaketime.tar.gz" | sha256sum -c -; \
    mkdir -p /usr/src/libfaketime; \
    tar -xzf libfaketime.tar.gz -C /usr/src/libfaketime --strip-components=1; \
    cp libfaketime.tar.gz "/usr/src/libfaketime-${LIBFAKETIME_VERSION}.tar.gz"

WORKDIR /usr/src/libfaketime

# Export CFLAGS so it cannot override upstream's own -DFAKE_* additions; the
# dry run checks the extra flags reached the compile line.
RUN set -eux; \
    export CFLAGS="${EXTRA_CFLAGS} -O2 -fPIC"; \
    compile="$(make -C src -B -n)"; \
    for flag in ${EXTRA_CFLAGS}; do \
      case "$compile" in \
        *"$flag"*) ;; \
        *) echo "build dropped flag $flag" >&2; exit 1 ;; \
      esac; \
    done; \
    make; \
    make install DESTDIR=/stage PREFIX="${INSTALL_PREFIX}"; \
    test -f "/stage${INSTALL_PREFIX}/lib/faketime/libfaketime.so.1"


FROM debian:${FINAL_BASE}

ARG BASE_TAG
ARG FINAL_BASE
ARG GLIBC
ARG LIBFAKETIME_VERSION
ARG LIBFAKETIME_URL
ARG LIBFAKETIME_SHA256
ARG EXTRA_CFLAGS
ARG INSTALL_PREFIX=/usr/local
ARG IMAGE_VERSION
ARG VCS_REF=""
ARG RELEASE_TAG=""

LABEL org.opencontainers.image.title="libfaketime" \
      org.opencontainers.image.description="upstream libfaketime ${LIBFAKETIME_VERSION} built once on glibc ${GLIBC} and carried on debian:${FINAL_BASE}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.licenses="GPL-2.0" \
      org.opencontainers.image.source="${LIBFAKETIME_URL}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      com.libfaketime.release="${RELEASE_TAG}" \
      com.libfaketime.version="${LIBFAKETIME_VERSION}" \
      com.libfaketime.source.url="${LIBFAKETIME_URL}" \
      com.libfaketime.source.sha256="${LIBFAKETIME_SHA256}" \
      com.libfaketime.build.base="debian:${BASE_TAG}" \
      com.libfaketime.build.glibc="${GLIBC}" \
      com.libfaketime.build.cflags="${EXTRA_CFLAGS}" \
      com.libfaketime.runtime.base="debian:${FINAL_BASE}" \
      com.libfaketime.install.prefix="${INSTALL_PREFIX}"

# Installed tree, exactly as upstream's install target laid it down. Nothing is
# added: this image carries the upstream release and nothing else.
COPY --from=build /stage${INSTALL_PREFIX}/ ${INSTALL_PREFIX}/
# Corresponding source for the GPL binary above.
COPY --from=build /usr/src/libfaketime-${LIBFAKETIME_VERSION}.tar.gz /usr/src/

RUN set -eux; \
    chmod 0755 "${INSTALL_PREFIX}/lib/faketime/"*.so.1; \
    ls -l "${INSTALL_PREFIX}/lib/faketime" "${INSTALL_PREFIX}/bin" /usr/src
