BUILDARCH ?= $(shell uname -m)
ARCH ?= $(BUILDARCH)

ifeq ($(BUILDARCH),aarch64)
        override BUILDARCH=arm64
endif
ifeq ($(BUILDARCH),x86_64)
        override BUILDARCH=amd64
endif
ifeq ($(ARCH),aarch64)
        override ARCH=arm64
endif
ifeq ($(ARCH),x86_64)
        override ARCH=amd64
endif
ifeq ($(ARCH),ppc64le)
        override ARCH=ppc64le
endif

ifeq ($(ARCH),arm64)
	QEMUARCH=aarch64
endif
ifeq ($(ARCH),ppc64le)
	QEMUARCH=ppc64le
endif

DOCKERFILE ?= Dockerfile.$(ARCH)
VERSION ?= latest
DEFAULTIMAGE ?= calico/go-build:$(VERSION)
ARCHIMAGE ?= $(DEFAULTIMAGE)-$(ARCH)
BUILDIMAGE ?= $(DEFAULTIMAGE)-$(BUILDARCH)
TEMP_DIR:=$(shell mktemp -d)
ALL_ARCH = amd64 arm64 ppc64le
QEMUVERSION=v2.9.1

MANIFEST_TOOL_DIR := $(shell mktemp -d)
export PATH := $(MANIFEST_TOOL_DIR):$(PATH)

MANIFEST_TOOL_VERSION := v0.7.0

space :=
space +=
comma := ,
prefix_linux = $(addprefix linux/,$(strip $1))
join_platforms = $(subst $(space),$(comma),$(call prefix_linux,$(strip $1)))

manifest-tool:
	curl -sSL https://github.com/estesp/manifest-tool/releases/download/$(MANIFEST_TOOL_VERSION)/manifest-tool-linux-amd64 > $(MANIFEST_TOOL_DIR)/manifest-tool
	chmod +x $(MANIFEST_TOOL_DIR)/manifest-tool

ARCHES=$(patsubst Dockerfile.%,%,$(wildcard Dockerfile.*))

all: all-build

push-manifest: manifest-tool
	manifest-tool push from-args --platforms $(call join_platforms,$(ALL_ARCH)) --template $(DEFAULTIMAGE)-ARCH --target $(DEFAULTIMAGE)

all-build: $(addprefix sub-build-,$(ALL_ARCH))
sub-build-%:
	$(MAKE) build ARCH=$*

build: calico/go-build

calico/go-build:
	cp ./* $(TEMP_DIR)
	cd $(TEMP_DIR) && sed -i "s|BASEIMAGE|$(BASEIMAGE)|g" $(DOCKERFILE)
	cd $(TEMP_DIR) && sed -i "s|ARCH|$(QEMUARCH)|g" $(DOCKERFILE)

ifeq ($(ARCH),amd64)
	# When building "normally" for amd64, remove the whole line, it has no part in the amd64 image
	cd $(TEMP_DIR) && sed -i "/CROSS_BUILD_/d" $(DOCKERFILE)
else
	docker run --rm --privileged multiarch/qemu-user-static:register --reset
	curl -sSL https://github.com/multiarch/qemu-user-static/releases/download/$(QEMUVERSION)/x86_64_qemu-$(QEMUARCH)-static.tar.gz | tar -xz -C $(TEMP_DIR)
	cd $(TEMP_DIR) && sed -i "s/CROSS_BUILD_//g" $(DOCKERFILE)
endif
	# Make sure we re-pull the base image to pick up security fixes.
	docker build --pull -t $(ARCHIMAGE) -f $(TEMP_DIR)/$(DOCKERFILE) $(TEMP_DIR)

all-push: $(addprefix sub-push-,$(ALL_ARCH))
sub-push-%:
	$(MAKE) push ARCH=$*

push: build
	docker push $(ARCHIMAGE)
	# to handle default case, because quay.io does not support manifest yet
ifeq ($(ARCH),amd64)
	docker tag $(ARCHIMAGE) quay.io/$(DEFAULTIMAGE)
	docker push quay.io/$(DEFAULTIMAGE)
endif

# Enable binfmt adding support for miscellaneous binary formats.
.PHONY: register
register:
ifeq ($(ARCH),amd64)
	docker run --rm --privileged multiarch/qemu-user-static:register --reset
endif


test: register
	for arch in $(ARCHES) ; do ARCH=$$arch $(MAKE) testcompile; done

testcompile:
	docker run --rm -e LOCAL_USER_ID=$(shell id -u) -e GOARCH=$(ARCH) -w /code -v ${PWD}:/code $(BUILDIMAGE) go build -o hello-$(ARCH) hello.go
	docker run --rm -v ${PWD}:/code $(BUILDIMAGE) /code/hello-$(ARCH) | grep -q "hello world"
	@echo "success"
