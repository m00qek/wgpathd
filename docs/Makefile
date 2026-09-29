# --- 1. CONFIGURATION ---
.ONESHELL:
.SHELLFLAGS = -ec

# Directory Resolution
DOCS_DIR     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT_ROOT := $(abspath $(DOCS_DIR)/..)

# Docker Image (Pinned to 9.x to avoid MkDocs 2.0 breaking changes)
MKDOCS_IMAGE := squidfunk/mkdocs-material:9.5.17
DOCS_PORT    ?= 8000
# Run as the invoking user so bin/site is not left owned by root.
MKDOCS_RUN   := docker run --rm --user $$(id -u):$$(id -g) -v $(PROJECT_ROOT):/docs

# The same image plus mike (devenv/services/docs/requirements.txt), git and node.
TOOLS_DIR    := $(PROJECT_ROOT)/devenv/services/docs
TOOLS_IMAGE  := wgpathd-docs:$(lastword $(subst :, ,$(MKDOCS_IMAGE)))
TOOLS_STAMP  := $(PROJECT_ROOT)/devenv/.built-docs
TOOLS_RUN    := $(MKDOCS_RUN) -w /docs -e HOME=/tmp --network none $(TOOLS_IMAGE)

# --- 2. PUBLIC INTERFACE ---
.PHONY: build build-mike test serve dev clean help

help:
	@echo "wgpathd Documentation Toolkit"
	@echo "Usage:"
	@echo "  make build       - Generate the static site in $(PROJECT_ROOT)/bin/site/ (strict)"
	@echo "  make build-mike  - Strict build with the versioned config, mkdocs.mike.yml"
	@echo "  make test        - Test the publishing scripts and the gh-pages 404 redirect"
	@echo "  make serve       - Run a live-reloading dev server on http://localhost:$(DOCS_PORT) (DOCS_PORT=<n> to change)"
	@echo "  make clean       - Remove the generated site directory"

build:
	@echo "Building static documentation..."
	$(MKDOCS_RUN) $(MKDOCS_IMAGE) build --strict

build-mike: $(TOOLS_STAMP)
	@echo "Building static documentation with mkdocs.mike.yml..."
	$(TOOLS_RUN) mkdocs build --strict --config-file mkdocs.mike.yml

test: $(TOOLS_STAMP)
	$(TOOLS_RUN) test/docs/run.sh

serve: dev
dev:
	@echo "Starting documentation server on http://localhost:$(DOCS_PORT) (Ctrl+C to stop)..."
	$(MKDOCS_RUN) -it -p $(DOCS_PORT):8000 $(MKDOCS_IMAGE)

clean:
	@echo "Cleaning up generated documentation..."
	rm -rf $(PROJECT_ROOT)/bin/site

$(TOOLS_STAMP): $(TOOLS_DIR)/Dockerfile $(TOOLS_DIR)/requirements.txt
	docker build -q -t $(TOOLS_IMAGE) --build-arg MKDOCS_IMAGE=$(MKDOCS_IMAGE) $(TOOLS_DIR) >/dev/null
	touch $@
