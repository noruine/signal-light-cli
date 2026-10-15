# signal-light — build, test and install shortcuts.
#
# Always passes --build-system native: CommandLineTools-only machines cannot
# initialize SwiftPM's default engine, and the flag is harmless where they can.

.DEFAULT_GOAL := build
CONFIGURATION ?= release

.PHONY: build install test lint format version clean help

build:  ## Build both executables ($(CONFIGURATION))
	swift build --build-system native -c $(CONFIGURATION)

# This target is the repo-level `install` people expect after a `git pull`:
# build, then hand the fresh binaries to the CLI's `upgrade` (first run
# installs, later runs update).
install: build  ## Build, then install or upgrade ~/.signal-light
	.build/$(CONFIGURATION)/signal-light upgrade

test:  ## Run the test suite
	scripts/test.sh

lint:  ## Format check, lint rules, CLI copy check
	@command -v swiftformat >/dev/null || { echo "swiftformat missing: brew install swiftformat"; exit 1; }
	@command -v swiftlint >/dev/null || { echo "swiftlint missing: brew install swiftlint"; exit 1; }
	swiftformat --lint .
	swiftlint --strict
	zsh scripts/check-cli-copy.sh

format:  ## Rewrite sources with swiftformat
	@command -v swiftformat >/dev/null || { echo "swiftformat missing: brew install swiftformat"; exit 1; }
	swiftformat .

version:  ## Check and update VERSION for changed product code
	scripts/version.sh $(if $(LEVEL),$(LEVEL),patch)

clean:  ## Remove build products
	rm -rf .build

help:  ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sed 's/$$(CONFIGURATION)/$(CONFIGURATION)/' \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'
