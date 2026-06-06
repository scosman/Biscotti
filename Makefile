.DEFAULT_GOAL := help
SHELL := /bin/bash

PACKAGES := Packages/BiscottiKit
LINT_PATHS := $(wildcard Packages App)

.PHONY: help bootstrap generate build test lint format build-app test-app precommit-checks hooks ci clean

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

bootstrap: ## Install dev tools via Homebrew
	@command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
	brew bundle --file=Brewfile

generate: ## Generate the Xcode project from project.yml
	cd App && xcodegen generate

build: ## Build all SPM packages
	swift build --package-path $(PACKAGES)

test: ## GATING: run package tests
	swift test --package-path $(PACKAGES)

lint: ## Check formatting + lint (non-mutating)
	swiftformat $(LINT_PATHS) --lint --cache ignore
	swiftlint lint --strict --no-cache $(LINT_PATHS)

format: ## Auto-format then autofix lint
	swiftformat $(LINT_PATHS) --cache ignore
	swiftlint lint --fix --no-cache $(LINT_PATHS)

precommit-checks: ## The pre-commit checks (format + lint + test); the hook and hooks-mcp both call this
	$(MAKE) format
	$(MAKE) lint
	$(MAKE) test

build-app: generate ## NON-GATING: build the app via xcodebuild (ad-hoc)
	cd App && xcodebuild -quiet -project Biscotti.xcodeproj -scheme Biscotti \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug CODE_SIGNING_ALLOWED=YES build

test-app: generate ## NON-GATING: app test scheme (empty for now)
	cd App && xcodebuild -quiet -project Biscotti.xcodeproj -scheme Biscotti \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug test

hooks: ## Enable the opt-in pre-commit hook
	git config core.hooksPath .githooks
	@echo "Pre-commit hook enabled (.githooks)."

ci: lint test build ## What the gating CI job runs

clean: ## Remove build artifacts + generated project
	rm -rf .build $(PACKAGES)/.build App/Biscotti.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/Biscotti-*
