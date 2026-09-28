OPENWRT_ARCH    ?= x86_64
OPENWRT_VERSION ?= 25.12.5
PKG_DEPENDS     := $(shell sed -n 's/^[[:space:]]*DEPENDS:=//p' openwrt/wgpathd/Makefile | tr ' ' '\n' | sed 's/^+//' | grep -v '^kmod-')
export OPENWRT_ARCH OPENWRT_VERSION PKG_DEPENDS

COMPOSE     := docker compose -f devenv/docker-compose.yaml
RUN          = $(COMPOSE) --progress quiet run --rm $(if $(CI),-T) openwrt
IMAGE_STAMP := devenv/.built-$(OPENWRT_ARCH)-$(OPENWRT_VERSION)
TEST_ARGS    = $(if $(FILTER),-f '$(FILTER)') $(if $(VERBOSE),-v) $(MODULES)

.PHONY: test unit integration watch lint shell image e2e lab-up lab-down lab-shell lab-fault package package-check docs docs-serve

test:        $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/test.sh all $(TEST_ARGS)
unit:        $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/test.sh unit $(TEST_ARGS)
integration: $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/test.sh integration $(TEST_ARGS)
watch:       $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/test.sh watch $(TEST_ARGS)
lint:        $(IMAGE_STAMP) ; @$(RUN) devenv/scripts/lint.sh
shell:       $(IMAGE_STAMP) ; @$(RUN) sh

image:
	$(COMPOSE) build --pull openwrt
	@touch $(IMAGE_STAMP)

$(IMAGE_STAMP): devenv/services/openwrt/Dockerfile openwrt/wgpathd/Makefile
	$(COMPOSE) build openwrt
	@touch $@

e2e:
	@devenv/scripts/e2e.sh $(SCENARIO)

lab-up:    ; @devenv/scripts/lab.sh up
lab-down:  ; @devenv/scripts/lab.sh down
lab-shell: ; @devenv/scripts/lab.sh shell $(NODE)
lab-fault: ; @devenv/scripts/lab.sh fault $(NAME) $(MS)

SDK_IMAGE := wgpathd-sdk:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)
PKG_DIR   := /sdk/package/wgpathd

package:
	docker build -q -t $(SDK_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION devenv/services/sdk >/dev/null
	@mkdir -p bin && chmod a+rwx bin
	docker run --rm $(if $(CI),,-t) -e VERBOSE \
		-v $(CURDIR)/openwrt/wgpathd/Makefile:$(PKG_DIR)/Makefile:ro \
		-v $(CURDIR)/src:$(PKG_DIR)/src:ro \
		-v $(CURDIR)/files:$(PKG_DIR)/files:ro \
		-v $(CURDIR)/devenv/services/sdk/build.sh:/usr/local/bin/build.sh:ro \
		-v $(CURDIR)/bin:/artifacts \
		$(SDK_IMAGE) /usr/local/bin/build.sh

PKGCHECK_IMAGE := wgpathd-pkgcheck:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)

# No network (the image carries the dependencies) and NET_ADMIN, so fw4 can load
# rules into the container's own, otherwise empty, network namespace.
package-check: package
	docker build -q -t $(PKGCHECK_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg PKG_DEPENDS="$(PKG_DEPENDS)" devenv/services/pkgcheck >/dev/null
	docker run --rm $(if $(CI),,-t) --network none --cap-add NET_ADMIN \
		-v $(CURDIR)/bin:/artifacts:ro \
		-v $(CURDIR)/devenv/scripts/package-check.sh:/usr/local/bin/package-check.sh:ro \
		$(PKGCHECK_IMAGE) /usr/local/bin/package-check.sh

docs:       ; @$(MAKE) -C docs build
docs-serve: ; @$(MAKE) -C docs serve
