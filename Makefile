VERSION   ?= 0.9.13
DISTRO    ?= 11
GLIBC     ?= 2.31
IMAGE     ?= arsiachou/libfaketime
PREFIX    ?= /usr/local
ENGINE    ?= podman
# Local builds behind a proxy need the host network namespace so that
# 127.0.0.1 inside the build container is the machine running podman:
#   with-proxy make build VERSION=0.9.10 NETWORK=host
NETWORK   ?=
# Stretch-era baselines are gone from deb.debian.org; a domestic mirror shortens
# the fetch without changing which packages are installed.
APT_MIRROR ?= archive.debian.org

# Baselines are keyed by glibc, so the tag always matches the compiled ABI.
BUILD_ROW     := $(shell awk -F'\t' -v g="$(GLIBC)" '!/^#/ && $$2 == g {printf "%s|%s|%s|%s", $$1, $$2, $$3, $$4}' docker/build-base.lock)
BUILD_PARTS   := $(subst |, ,$(BUILD_ROW))
BASE_TAG      := $(word 1,$(BUILD_PARTS))
APT_ARCHIVE   := $(word 3,$(BUILD_PARTS))
MAKE_MODE     := $(word 4,$(BUILD_PARTS))
CARRIER_ROW   := $(shell awk -F'\t' -v d="$(DISTRO)" '!/^#/ && $$1 == d {printf "%s|%s", $$2, $$3}' docker/bases.lock)
CARRIER_PARTS := $(subst |, ,$(CARRIER_ROW))
FINAL_BASE    := $(word 1,$(CARRIER_PARTS))
CARRIER_GLIBC := $(word 2,$(CARRIER_PARTS))

# One row supplies the tag, url and hash so they cannot drift apart.
ROW          := $(shell awk -F'\t' '!/^#/ && $$1=="$(VERSION)"{printf "%s|%s", $$2, $$3}' docker/versions.lock)
ROW_PARTS    := $(subst |, ,$(ROW))
LIBFAKETIME_URL    := $(word 1,$(ROW_PARTS))
LIBFAKETIME_SHA256 := $(word 2,$(ROW_PARTS))

# A baseline ships the compiler that judges the warnings, so the flags a release
# needs are per baseline; an absent file means the release needs none there.
CFLAGS_FILE  := docker/cflags/$(VERSION)/$(GLIBC).flags
EXTRA_CFLAGS := $(shell ./scripts/cflags.sh $(VERSION) $(GLIBC))

# The point release is only known from the carrier image, so TAG stops at the
# distro line.
TAG ?= v$(VERSION)-glibc$(GLIBC)-debian$(DISTRO)

BUILD_ARGS := \
  $(if $(NETWORK),--network=$(NETWORK)) \
  --build-arg BASE_TAG=$(BASE_TAG) \
  --build-arg GLIBC=$(GLIBC) \
  --build-arg APT_ARCHIVE=$(APT_ARCHIVE) \
  --build-arg APT_MIRROR=$(APT_MIRROR) \
  --build-arg TOOLCHAIN_MAKE=$(MAKE_MODE) \
  --build-arg FINAL_BASE=$(FINAL_BASE) \
  --build-arg LIBFAKETIME_VERSION=$(VERSION) \
  --build-arg LIBFAKETIME_URL=$(LIBFAKETIME_URL) \
  --build-arg LIBFAKETIME_SHA256=$(LIBFAKETIME_SHA256) \
  --build-arg EXTRA_CFLAGS="$(EXTRA_CFLAGS)" \
  --build-arg INSTALL_PREFIX=$(PREFIX) \
  --build-arg IMAGE_VERSION=$(TAG) \
  --build-arg VCS_REF=$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown) \
  --build-arg RELEASE_TAG=$(shell git describe --tags --exact-match 2>/dev/null || echo local)

.PHONY: build test push lock clean check-pin check-base check-flags

# Never publish a tag for a version this repository did not compile.
check-pin:
	@case "$(LIBFAKETIME_SHA256)" in \
	  ""|TODO*) \
	    echo "refusing to publish $(TAG): $(VERSION) is not pinned in docker/versions.lock" >&2; \
	    exit 1 ;; \
	esac

check-base:
	@test -n "$(BUILD_ROW)" || { \
	  echo "no build baseline with glibc $(GLIBC) in docker/build-base.lock" >&2; \
	  exit 1; \
	}
	@test -n "$(MAKE_MODE)" || { \
	  echo "build baseline glibc $(GLIBC) has no make value" >&2; \
	  exit 1; \
	}
	@test -n "$(FINAL_BASE)" || { \
	  echo "no carrier for distro $(DISTRO) in docker/bases.lock" >&2; \
	  exit 1; \
	}
	@test -n "$(CARRIER_GLIBC)" || { \
	  echo "carrier for distro $(DISTRO) has no glibc value" >&2; \
	  exit 1; \
	}
	@lowest="$$(printf '%s\n%s\n' '$(GLIBC)' '$(CARRIER_GLIBC)' | sort -V | head -1)"; \
	if [ "$$lowest" != "$(GLIBC)" ]; then \
	  echo "carrier debian:$(FINAL_BASE) runs glibc $(CARRIER_GLIBC), below baseline glibc $(GLIBC)" >&2; \
	  exit 1; \
	fi

# An overlay naming a release or a baseline that no longer exists would silently
# stop applying; refuse it instead.
check-flags:
	@./scripts/cflags.sh --check

build: check-base check-flags
	@echo "extra flags: $(if $(wildcard $(CFLAGS_FILE)),$(CFLAGS_FILE),none)"
	$(ENGINE) build $(BUILD_ARGS) -t $(IMAGE):$(TAG) .

test: build
	CONTAINER_ENGINE=$(ENGINE) GLIBC_FLOOR=$(GLIBC) ./scripts/capabilities.sh --gate $(IMAGE):$(TAG)

push: check-pin build
	$(ENGINE) push $(IMAGE):$(TAG)

lock:
	./scripts/update-lock.sh $(ARGS)

clean:
	-$(ENGINE) rmi $(IMAGE):$(TAG)
