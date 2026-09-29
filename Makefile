OPENWRT_ARCH    ?= x86_64
OPENWRT_VERSION ?= 25.12.5
# The feed packages a package in openwrt/wgpathd/Makefile depends on: not kmods, not its sibling.
feed_depends = $(shell sed -n '/^define Package\/$(1)$$/,/^endef/s/^[[:space:]]*DEPENDS:=//p' openwrt/wgpathd/Makefile \
	| tr ' ' '\n' | sed 's/^+//' | grep -v -e '^kmod-' -e '^wgpathd$$')
pkg_field       = $(shell sed -n 's/^PKG_$(1):=//p' openwrt/wgpathd/Makefile)
PKG_FULLVERSION := $(call pkg_field,VERSION)-r$(call pkg_field,RELEASE)
PKG_DEPENDS     := $(call feed_depends,wgpathd)
APP_DEPENDS     := $(call feed_depends,luci-app-wgpathd)
# Keyed by the image's inputs, so worktrees with different Dockerfiles don't overwrite each other's image.
IMAGE_TAG       := $(OPENWRT_ARCH)-$(OPENWRT_VERSION)-$(shell { cat devenv/services/openwrt/Dockerfile; echo '$(PKG_DEPENDS)'; } | sha256sum | cut -c1-12)
export OPENWRT_ARCH OPENWRT_VERSION PKG_DEPENDS IMAGE_TAG

COMPOSE     := docker compose -f devenv/docker-compose.yaml
RUN          = $(COMPOSE) --progress quiet run --rm $(if $(CI),-T) openwrt
IMAGE_STAMP := devenv/.built-$(IMAGE_TAG)
TEST_ARGS    = $(if $(FILTER),-f '$(FILTER)') $(if $(VERBOSE),-v) $(MODULES)

.PHONY: test unit integration watch lint shell image e2e lab-up lab-down lab-shell lab-fault package package-check browser docs docs-mike docs-test docs-serve

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
		-v $(CURDIR)/luci:$(PKG_DIR)/luci:ro \
		-v $(CURDIR)/devenv/services/sdk/build.sh:/usr/local/bin/build.sh:ro \
		-v $(CURDIR)/bin:/artifacts \
		$(SDK_IMAGE) /usr/local/bin/build.sh

PKGCHECK_IMAGE := wgpathd-pkgcheck:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)

# No network (the image carries the dependencies) and NET_ADMIN, so fw4 can load
# rules into the container's own, otherwise empty, network namespace.
package-check: package
	docker build -q -t $(PKGCHECK_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg PKG_DEPENDS="$(PKG_DEPENDS)" --build-arg APP_DEPENDS="$(APP_DEPENDS)" \
		devenv/services/pkgcheck >/dev/null
	docker run --rm $(if $(CI),,-t) --network none --cap-add NET_ADMIN -e PKG_FULLVERSION=$(PKG_FULLVERSION) \
		-v $(CURDIR)/bin:/artifacts:ro \
		-v $(CURDIR)/devenv/scripts/package-check.sh:/usr/local/bin/package-check.sh:ro \
		$(PKGCHECK_IMAGE) /usr/local/bin/package-check.sh

LUCI_IMAGE    := wgpathd-luci:$(OPENWRT_ARCH)-$(OPENWRT_VERSION)
BROWSER_IMAGE := wgpathd-browser:$(shell sed -n 's/.*"@playwright\/test": "\(.*\)".*/\1/p' devenv/services/browser/package.json)

# The LuCI pages against a fake wgpathd; see devenv/scripts/browser.sh.
browser: package
	docker build -q -t $(LUCI_IMAGE) --build-arg OPENWRT_ARCH --build-arg OPENWRT_VERSION \
		--build-arg PKG_DEPENDS="$(PKG_DEPENDS)" --build-arg APP_DEPENDS="$(APP_DEPENDS)" \
		devenv/services/luci >/dev/null
	docker build -q -t $(BROWSER_IMAGE) devenv/services/browser >/dev/null
	@LUCI_IMAGE=$(LUCI_IMAGE) BROWSER_IMAGE=$(BROWSER_IMAGE) PKG_FULLVERSION=$(PKG_FULLVERSION) FILTER='$(FILTER)' \
		devenv/scripts/browser.sh

docs:       ; @$(MAKE) -C docs build
docs-mike:  ; @$(MAKE) -C docs build-mike
docs-test:  ; @$(MAKE) -C docs test
docs-serve: ; @$(MAKE) -C docs serve
