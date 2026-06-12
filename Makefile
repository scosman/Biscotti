.DEFAULT_GOAL := help
SHELL := /bin/bash

PACKAGES := Packages/BiscottiKit Packages/Transcription Packages/AudioCapture
LINT_PATHS := $(wildcard Packages App ManualTestApp XPCServices)

# SwiftLint is pinned to an exact version. Homebrew cannot pin a formula version
# in a Brewfile, so a brew-installed SwiftLint drifts between machines and CI —
# and different versions disagree about which rules fire (e.g. force_unwrapping).
# We vendor the pinned portable binary under .tools/ and every target invokes
# $(SWIFTLINT) instead of whatever happens to be on PATH. Bump the version here
# (and the SHA below) to upgrade; the version is in the path so it re-downloads.
SWIFTLINT_VERSION := 0.63.3
SWIFTLINT_SHA256  := fb045e85e7cb3374f42a4840b6b85a0106302afa69035c0c6f29af4a44c810b6
TOOLS_DIR := .tools
SWIFTLINT_DIR := $(TOOLS_DIR)/swiftlint-$(SWIFTLINT_VERSION)
SWIFTLINT := $(SWIFTLINT_DIR)/swiftlint

.PHONY: help bootstrap generate build test test-ai lint format build-app test-app precommit-checks hooks ci clean manual-tests-check

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

bootstrap: $(SWIFTLINT) ## Install dev tools via Homebrew + pinned SwiftLint
	@command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
	brew bundle --file=Brewfile

# Fetch + verify the pinned SwiftLint portable binary on demand. The version is
# encoded in the path, so bumping SWIFTLINT_VERSION forces a fresh download.
$(SWIFTLINT):
	@echo "==> Fetching pinned SwiftLint $(SWIFTLINT_VERSION)"
	@mkdir -p "$(SWIFTLINT_DIR)"
	@curl -fL --retry 3 -o "$(SWIFTLINT_DIR)/portable_swiftlint.zip" \
	  "https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/portable_swiftlint.zip"
	@if [ -n "$(SWIFTLINT_SHA256)" ]; then \
	  echo "$(SWIFTLINT_SHA256)  $(SWIFTLINT_DIR)/portable_swiftlint.zip" | shasum -a 256 -c - ; \
	else \
	  echo "WARNING: SWIFTLINT_SHA256 is unset — skipping integrity check"; \
	fi
	@cd "$(SWIFTLINT_DIR)" && unzip -o -q portable_swiftlint.zip
	@chmod +x "$(SWIFTLINT)"
	@touch "$(SWIFTLINT)"

generate: ## Generate Xcode projects from project.yml files
	cd App && xcodegen generate
	cd ManualTestApp && xcodegen generate

build: ## Build all SPM packages
	@for pkg in $(PACKAGES); do echo "==> Building $$pkg"; swift build --package-path $$pkg || exit 1; done

test: ## GATING: run package tests
	@for pkg in $(PACKAGES); do \
	  echo "==> Testing $$pkg"; \
	  swift test --package-path $$pkg 2>&1 \
	    | grep -E 'recorded an issue|with [0-9]+ issue|Test run with [0-9]|Executed [0-9]+ test|: error:|error generated|no such module|cannot find|Build complete!' ; \
	  rc=$${PIPESTATUS[0]}; [ $$rc -eq 0 ] || exit $$rc; \
	done

test-ai: ## NON-GATING: heavy AI/model tests (downloads GBs; not in CI)
	BISCOTTI_RUN_AI_TESTS=1 swift test --package-path Packages/Transcription

lint: $(SWIFTLINT) ## Check formatting + lint (non-mutating)
	swiftformat $(LINT_PATHS) --lint --quiet --cache ignore
	$(SWIFTLINT) lint --strict --quiet --no-cache $(LINT_PATHS)

format: $(SWIFTLINT) ## Auto-format then autofix lint
	swiftformat $(LINT_PATHS) --quiet --cache ignore
	$(SWIFTLINT) lint --fix --quiet --no-cache $(LINT_PATHS)

precommit-checks: ## The pre-commit checks (format + lint + test); the hook and hooks-mcp both call this
	$(MAKE) format
	$(MAKE) lint
	$(MAKE) test

build-app: generate ## NON-GATING: build both apps via xcodebuild (ad-hoc)
	cd App && xcodebuild -quiet -project Biscotti.xcodeproj -scheme Biscotti \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug CODE_SIGNING_ALLOWED=YES build
	cd ManualTestApp && xcodebuild -quiet -project ManualTestApp.xcodeproj -scheme ManualTestApp \
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

manual-tests-check: ## Check that all manual test step IDs have been run (expected RED until Phase 4.5)
	swift run --package-path Packages/BiscottiKit manual-tests-check ManualTestApp/Results/manual_test_results.json

clean: ## Remove build artifacts + generated projects
	rm -rf .build App/Biscotti.xcodeproj ManualTestApp/ManualTestApp.xcodeproj
	@for pkg in $(PACKAGES); do rm -rf $$pkg/.build; done
	rm -rf ~/Library/Developer/Xcode/DerivedData/Biscotti-*
	rm -rf ~/Library/Developer/Xcode/DerivedData/ManualTestApp-*
