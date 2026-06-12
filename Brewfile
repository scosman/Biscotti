brew "xcodegen"
# swiftlint is NOT installed via brew — it's version-pinned and vendored under
# .tools/ by the Makefile (see SWIFTLINT_VERSION). brew can't pin a formula
# version, and version drift changes which lint rules fire. `make lint`/`format`
# fetch the pinned binary automatically.
brew "swiftformat"
brew "node"
# uv (for hooks_mcp/uvx) is already installed outside Homebrew — NOT listed here.
