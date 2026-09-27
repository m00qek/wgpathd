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

# --- 2. PUBLIC INTERFACE ---
.PHONY: build serve dev clean help

help:
	@echo "wgpathd Documentation Toolkit"
	@echo "Usage:"
	@echo "  make build  - Generate the static site in $(PROJECT_ROOT)/bin/site/ (strict)"
	@echo "  make serve  - Run a live-reloading dev server on http://localhost:$(DOCS_PORT) (DOCS_PORT=<n> to change)"
	@echo "  make clean  - Remove the generated site directory"

build:
	@echo "Building static documentation..."
	$(MKDOCS_RUN) $(MKDOCS_IMAGE) build --strict

serve: dev
dev:
	@echo "Starting documentation server on http://localhost:$(DOCS_PORT) (Ctrl+C to stop)..."
	$(MKDOCS_RUN) -it -p $(DOCS_PORT):8000 $(MKDOCS_IMAGE)

clean:
	@echo "Cleaning up generated documentation..."
	rm -rf $(PROJECT_ROOT)/bin/site
