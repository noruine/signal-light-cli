#!/bin/zsh
# Packages the CLI as a zip anyone can unzip and install from: the
# signal-light binary, the signal-light-hooks it installs alongside, and the
# docs that explain both.
#
# Usage: scripts/package-cli.sh
# Output: output/cli-package/signal-light-<version>-macos-<arch>.zip

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "signal-light packages only on macOS." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_root="$repo_root/output/cli-package"

cd "$repo_root"

# CLT-only machines can't initialize SwiftPM's default engine; the flag is
# harmless where the default one works.
swift build --build-system native -c release --product signal-light
swift build --build-system native -c release --product signal-light-hooks

bin_dir="$(swift build --build-system native -c release --show-bin-path)"
version="$("$bin_dir/signal-light" --version)"

package_dir="$package_root/signal-light-$version"
zip_path="$package_root/signal-light-$version-macos-$(uname -m).zip"

rm -rf "$package_dir" "$zip_path"
mkdir -p "$package_dir"

cp "$bin_dir/signal-light" "$package_dir/signal-light"
cp "$bin_dir/signal-light-hooks" "$package_dir/signal-light-hooks"
cp "$repo_root/README.md" "$package_dir/README.md"

# --norsrc/--noextattr: ship only the files, not AppleDouble metadata that
# other unzip tools would surface as junk `._*` entries.
ditto -c -k --norsrc --noextattr --keepParent "$package_dir" "$zip_path"

echo ""
echo "Packaged $zip_path"
echo "  version: signal-light $version"
echo "  sha256:  $(shasum -a 256 "$zip_path" | awk '{print $1}')"
