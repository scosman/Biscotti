.DEFAULT_GOAL := help
SHELL := /bin/bash

PACKAGES := Packages/BiscottiKit
LINT_PATHS := $(wildcard Packages App)

.PHONY: help bootstrap build test lint format clean

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

bootstrap: ## Install dev tools via Homebrew
	@command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
	brew bundle --file=Brewfile

build: ## Build all SPM packages
	swift build --package-path $(PACKAGES)

test: ## GATING: run package tests
	swift test --package-path $(PACKAGES)

lint: ## Check formatting + lint (non-mutating)
	swiftformat --lint $(LINT_PATHS)
	swiftlint lint --strict $(LINT_PATHS)

format: ## Auto-format then autofix lint
	swiftformat $(LINT_PATHS)
	swiftlint lint --fix $(LINT_PATHS)

clean: ## Remove build artifacts + generated project
	rm -rf .build $(PACKAGES)/.build App/Biscotti.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/Biscotti-*
