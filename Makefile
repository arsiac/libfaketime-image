VERSION   ?= 0.9.13
DISTRO    ?= 11
IMAGE     ?= arsiachou/libfaketime
PREFIX    ?= /usr/local
ENGINE    ?= podman
# Local builds behind a proxy need the host network namespace so that
# 127.0.0.1 inside the build container is the machine running podman:
#   with-proxy make build VERSION=0.9.10 NETWORK=host
NETWORK   ?=

# One build baseline for every artifact; one carrier image per target distro.
BUILD_ROW    := $(shell awk -F'\t' '!/^#/ && NF {printf "%s|%s|%s", $$1, $$2, $$3}' docker/build-base.lock)
BUILD_PARTS  := $(subst |, ,$(BUILD_ROW))
BASE_TAG     := $(word 1,$(BUILD_PARTS))
GLIBC        := $(word 2,$(BUILD_PARTS))
APT_ARCHIVE  := $(word 3,$(BUILD_PARTS))
FINAL_BASE   := $(shell awk -F'\t' -v d="$(DISTRO)" '!/^#/ && $$1 == d { print $$2 }' docker/bases.lock)

# Pull the pin for this version out of docker/versions.lock so the tag, the
# url, the hash and the compile flags can never drift apart.
ROW          := $(shell awk -F'\t' '!/^#/ && $$1=="$(VERSION)"{printf "%s|%s|%s", $$2, $$3, $$4}' docker/versions.lock)
ROW_PARTS    := $(subst |, ,$(ROW))
LIBFAKETIME_URL    := $(word 1,$(ROW_PARTS))
LIBFAKETIME_SHA256 := $(word 2,$(ROW_PARTS))
EXTRA_CFLAGS       := $(wordlist 3,99,$(ROW_PARTS))

# Tags the distro line, not the exact point release: the point release is only
# known after the carrier image exists, and release.yml derives it from there.
TAG ?= v$(VERSION)-glibc$(GLIBC)-debian$(DISTRO)

BUILD_ARGS := \
  $(if $(NETWORK),--network=$(NETWORK)) \
  --build-arg BASE_TAG=$(BASE_TAG) \
  --build-arg GLIBC=$(GLIBC) \
  --build-arg APT_ARCHIVE=$(APT_ARCHIVE) \
  --build-arg FINAL_BASE=$(FINAL_BASE) \
  --build-arg LIBFAKETIME_VERSION=$(VERSION) \
  --build-arg LIBFAKETIME_URL=$(LIBFAKETIME_URL) \
  --build-arg LIBFAKETIME_SHA256=$(LIBFAKETIME_SHA256) \
  --build-arg EXTRA_CFLAGS="$(EXTRA_CFLAGS)" \
  --build-arg INSTALL_PREFIX=$(PREFIX) \
  --build-arg IMAGE_VERSION=$(TAG) \
  --build-arg VCS_REF=$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown) \
  --build-arg RELEASE_TAG=$(shell git describe --tags --exact-match 2>/dev/null || echo local)

.PHONY: build test push lock clean check-pin

# Publishing a tag that claims a version this repository did not compile is the
# one mistake that cannot be undone, so only the publish targets are gated.
check-pin:
	@case "$(LIBFAKETIME_SHA256)" in \
	  ""|TODO*) \
	    echo "refusing to publish $(TAG): $(VERSION) is not pinned in docker/versions.lock" >&2; \
	    exit 1 ;; \
	esac

build:
	$(ENGINE) build $(BUILD_ARGS) -t $(IMAGE):$(TAG) .

test: build
	CONTAINER_ENGINE=$(ENGINE) GLIBC_FLOOR=$(GLIBC) ./test.sh $(IMAGE):$(TAG)

push: check-pin build
	$(ENGINE) push $(IMAGE):$(TAG)

lock:
	./scripts/update-lock.sh $(ARGS)

clean:
	-$(ENGINE) rmi $(IMAGE):$(TAG)
