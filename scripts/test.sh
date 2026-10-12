#!/bin/zsh
# Runs the test suite.
#
# A CommandLineTools-only machine ships Testing.framework outside the default
# search path, so the flags below are what makes `swift test` work there; with
# a full Xcode installed the plain command is enough.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

clt_frameworks="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
if [[ -d "$clt_frameworks" && ! -d /Applications/Xcode.app ]]; then
    exec swift test --build-system native \
        -Xswiftc -F -Xswiftc "$clt_frameworks" \
        -Xlinker -F -Xlinker "$clt_frameworks"
fi

exec swift test "$@"
