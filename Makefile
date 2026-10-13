# signal-light — build, test and install shortcuts.
#
# Always passes --build-system native: CommandLineTools-only machines cannot
# initialize SwiftPM's default engine, and the flag is harmless where they can.

.DEFAULT_GOAL := build
CONFIGURATION ?= release

.PHONY: build install test lint format clean help

build:  ## Build both executables ($(CONFIGURATION))
	swift build --build-system native -c $(CONFIGURATION)

# The CLI's `upgrade` is the install-or-upgrade step: it installs when
# nothing is there yet and words the result accordingly; `install` is the
# repo-level verb people expect after a `git pull`.
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

clean:  ## Remove build products
	rm -rf .build

help:  ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sed 's/$$(CONFIGURATION)/$(CONFIGURATION)/' \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'
