brew "xcodegen"
# Neither swiftlint nor swiftformat is installed via brew — both are
# version-pinned and vendored under .tools/ by the Makefile (see
# SWIFTLINT_VERSION / SWIFTFORMAT_VERSION). brew can't pin a formula version, and
# version drift changes which rules fire (e.g. swiftformat 0.62 turned on
# wrapIfStatementBodies by default). `make lint`/`format` fetch the pinned
# binaries automatically.
brew "node"
# uv (for hooks_mcp/uvx) is already installed outside Homebrew — NOT listed here.
