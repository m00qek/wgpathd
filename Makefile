OPENWRT_ARCH    ?= x86_64
OPENWRT_VERSION ?= 25.12.5
PKG_DEPENDS     := $(shell sed -n 's/^[[:space:]]*DEPENDS:=//p' openwrt/wgpathd/Makefile | tr ' ' '\n' | sed 's/^+//' | grep -v '^kmod-')
export OPENWRT_ARCH OPENWRT_VERSION PKG_DEPENDS

COMPOSE     := docker compose -f devenv/docker-compose.yaml
RUN          = $(COMPOSE) --progress quiet run --rm $(if $(CI),-T) openwrt
IMAGE_STAMP := devenv/.built-$(OPENWRT_ARCH)-$(OPENWRT_VERSION)
TEST_ARGS    = $(if $(FILTER),-f '$(FILTER)') $(if $(VERBOSE),-v) $(MODULES)

.PHONY: test unit integration watch lint shell image e2e

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
	@echo "e2e harness not built yet (see the design record, E2E test harness)" >&2; exit 1
