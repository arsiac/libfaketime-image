# syntax=docker/dockerfile:1

# One artifact per baseline in docker/build-base.lock, copied into every
# compatible carrier in docker/bases.lock.
ARG BASE_IMAGE=debian:11-slim
ARG GLIBC=2.31
ARG ARCHIVED=1
ARG APT_MIRROR=archive.debian.org
ARG YUM_MIRROR=https://vault.centos.org
ARG FINAL_IMAGE=debian:11-slim
ARG TOOLCHAIN_MAKE=system

# Depends only on the baseline, so BuildKit reuses it across its carriers.
FROM ${BASE_IMAGE} AS toolchain

# ARGs declared before the first FROM are not visible in stages; the ones the
# RUN uses are re-declared here.
ARG ARCHIVED
ARG APT_MIRROR
ARG YUM_MIRROR
ARG GLIBC
ARG TOOLCHAIN_MAKE
ARG MAKE_VERSION=4.4.1
ARG MAKE_SHA256=dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3

# For archived releases: Debian switches to archive.debian.org with signature
# checks relaxed and -updates/-backports dropped; CentOS is read from the vault,
# whose paths carry the point release instead of $releasever (/centos on amd64,
# /altarch elsewhere). The published glibc is asserted against the toolchain.
RUN set -eux; \
    libc="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"; \
    if [ "$libc" != "${GLIBC}" ]; then \
      echo "toolchain reports glibc $libc, docker/build-base.lock says ${GLIBC}" >&2; \
      exit 1; \
    fi; \
    if command -v apt-get > /dev/null; then \
      if [ "${ARCHIVED}" = "1" ]; then \
        sed -i \
          -e "s|deb.debian.org/debian|${APT_MIRROR}/debian|g" \
          -e "s|security.debian.org/debian-security|${APT_MIRROR}/debian-security|g" \
          -e '/-updates/d' \
          -e '/-backports/d' \
          /etc/apt/sources.list; \
        apt-get -o Acquire::Check-Valid-Until=false \
                -o Acquire::AllowInsecureRepositories=true update; \
        apt-get install -y --allow-unauthenticated --no-install-recommends \
                build-essential ca-certificates curl patch; \
      else \
        apt-get update; \
        apt-get install -y --no-install-recommends build-essential ca-certificates curl patch; \
      fi; \
      rm -rf /var/lib/apt/lists/*; \
    else \
      if [ "${ARCHIVED}" = "1" ]; then \
        point="$(sed -n 's/^CentOS Linux release \([0-9.]*\) .*/\1/p' /etc/centos-release)"; \
        test -n "$point"; \
        sed -i \
          -e '/^mirrorlist=/d' \
          -e "s|^#baseurl=http://mirror.centos.org/centos/[^/]*|baseurl=${YUM_MIRROR}/$point|" \
          -e "s|^#baseurl=http://mirror.centos.org/altarch/[^/]*|baseurl=${YUM_MIRROR}/altarch/$point|" \
          /etc/yum.repos.d/CentOS-Base.repo; \
        grep -q "^baseurl=${YUM_MIRROR}/\(altarch/\)\?$point/" /etc/yum.repos.d/CentOS-Base.repo; \
      fi; \
      yum -y install gcc make patch ca-certificates curl; \
      rm -rf /var/cache/yum; \
    fi

# Some baselines ship a make too old to parse libfaketime's Makefile; build the
# pinned release with the system make and install only its binary.
RUN set -eux; \
    if [ "${TOOLCHAIN_MAKE}" = "system" ]; then \
      make --version | head -1; \
    else \
      if [ "${TOOLCHAIN_MAKE}" != "${MAKE_VERSION}" ]; then \
        echo "make ${TOOLCHAIN_MAKE} is not pinned in the Dockerfile" >&2; \
        exit 1; \
      fi; \
      curl --retry 3 --retry-delay 2 -fsSL -o /tmp/make.tar.gz "https://ftp.gnu.org/gnu/make/make-${MAKE_VERSION}.tar.gz"; \
      echo "${MAKE_SHA256}  /tmp/make.tar.gz" | sha256sum -c -; \
      mkdir -p /tmp/make; \
      tar -xzf /tmp/make.tar.gz -C /tmp/make --strip-components=1; \
      (cd /tmp/make && ./configure --prefix=/usr/local && make -j"$(nproc)" && make install-exec); \
      rm -rf /tmp/make /tmp/make.tar.gz; \
      /usr/local/bin/make --version | head -1 | grep -F "GNU Make ${TOOLCHAIN_MAKE}"; \
    fi


FROM toolchain AS build

ARG TOOLCHAIN_MAKE
ARG GLIBC
ARG TARGETARCH
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

# Patches are keyed by version, architecture and glibc baseline; an absent or
# empty directory leaves upstream's source untouched. TARGETARCH is the
# builder's, so a classic builder would silently match nothing.
COPY patches/ /tmp/patches/
RUN set -eux; \
    : "${TARGETARCH:?TARGETARCH is undefined; cannot resolve the patch directory}"; \
    mkdir -p /usr/src/corresponding; \
    cp "/usr/src/libfaketime-${LIBFAKETIME_VERSION}.tar.gz" /usr/src/corresponding/; \
    dir="/tmp/patches/${LIBFAKETIME_VERSION}/${TARGETARCH}/${GLIBC}"; \
    if [ -d "$dir" ]; then \
      for p in "$dir"/*.patch; do \
        [ -f "$p" ] || continue; \
        patch -p1 --batch < "$p"; \
        cp "$p" /usr/src/corresponding/; \
      done; \
    fi

# Export CFLAGS so it cannot override upstream's own -DFAKE_* additions; the
# dry run checks the extra flags reached the compile line.
RUN set -eux; \
    export CFLAGS="${EXTRA_CFLAGS} -O2 -fPIC"; \
    mk=make; \
    if [ "${TOOLCHAIN_MAKE}" != "system" ]; then mk=/usr/local/bin/make; fi; \
    compile="$("$mk" -C src -B -n)"; \
    for flag in ${EXTRA_CFLAGS}; do \
      case "$compile" in \
        *"$flag"*) ;; \
        *) echo "build dropped flag $flag" >&2; exit 1 ;; \
      esac; \
    done; \
    "$mk"; \
    "$mk" install DESTDIR=/stage PREFIX="${INSTALL_PREFIX}"; \
    test -f "/stage${INSTALL_PREFIX}/lib/faketime/libfaketime.so.1"


FROM ${FINAL_IMAGE}

ARG BASE_IMAGE
ARG FINAL_IMAGE
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
      org.opencontainers.image.description="upstream libfaketime ${LIBFAKETIME_VERSION} built once on glibc ${GLIBC} and carried on ${FINAL_IMAGE}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.licenses="GPL-2.0" \
      org.opencontainers.image.source="${LIBFAKETIME_URL}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      com.libfaketime.release="${RELEASE_TAG}" \
      com.libfaketime.version="${LIBFAKETIME_VERSION}" \
      com.libfaketime.source.url="${LIBFAKETIME_URL}" \
      com.libfaketime.source.sha256="${LIBFAKETIME_SHA256}" \
      com.libfaketime.build.base="${BASE_IMAGE}" \
      com.libfaketime.build.glibc="${GLIBC}" \
      com.libfaketime.build.cflags="${EXTRA_CFLAGS}" \
      com.libfaketime.runtime.base="${FINAL_IMAGE}" \
      com.libfaketime.install.prefix="${INSTALL_PREFIX}"

# Installed tree, exactly as upstream's install target laid it down.
COPY --from=build /stage${INSTALL_PREFIX}/ ${INSTALL_PREFIX}/
# Corresponding source for the GPL binary above: the upstream release and, when
# one was applied, the patch.
COPY --from=build /usr/src/corresponding/ /usr/src/

RUN set -eux; \
    chmod 0755 "${INSTALL_PREFIX}/lib/faketime/"*.so.1; \
    ls -l "${INSTALL_PREFIX}/lib/faketime" "${INSTALL_PREFIX}/bin" /usr/src
