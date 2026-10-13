#!/bin/zsh
# Keeps the CLI core's user-facing copy terse.
#
# The product's voice drops the 了 particle from command output: state lines
# read "已保存" / "已开启", not "存好了" / "开启好了". The ability forms
# (不了 / 为了 / 除了) are not that particle and stay as they are — removing
# 了 there would change the meaning, not tighten the copy.
#
# It also pins the key-hint vocabulary: hint text must come from
# KeyHint / Terminal.keyBar, so the glued legacy forms (回车确认, 空格勾选,
# ↑/↓ 选择, 按回车…) fail the check instead of drifting back in.
#
# Usage: scripts/check-cli-copy.sh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import pathlib
import re
import sys

sources = pathlib.Path(sys.argv[1]) / "Sources" / "SignalLightCLICore"
literal = re.compile(r'"((?:[^"\\]|\\.)*)"')
allowed = re.compile(r"不了|为了|除了")

hits: list[str] = []
for path in sorted(sources.rglob("*.swift")):
    for number, line in enumerate(path.read_text().split("\n"), 1):
        if line.strip().startswith("//"):
            continue
        for match in literal.finditer(line):
            text = match.group(1)
            if "了" in text and not allowed.search(text):
                hits.append(f"{path.relative_to(sources.parent.parent)}:{number}: {text}")

if hits:
    print("CLI copy uses 了 outside 不了 / 为了 / 除了:")
    for hit in hits:
        print(f"  {hit}")
    print("")
    print("Say 已保存 / 已开启 / 已改好 instead of 存好了 / 开启好了 / 改好了.")
    sys.exit(1)

stale_hints = re.compile(r"回车确认|空格勾选|↑/↓ 选择|按回车")
hint_hits: list[str] = []
for path in sorted(sources.rglob("*.swift")):
    for number, line in enumerate(path.read_text().split("\n"), 1):
        if line.strip().startswith("//"):
            continue
        for match in literal.finditer(line):
            text = match.group(1)
            if stale_hints.search(text):
                hint_hits.append(f"{path.relative_to(sources.parent.parent)}:{number}: {text}")

if hint_hits:
    print("Key-hint text drifted back to a legacy form:")
    for hit in hint_hits:
        print(f"  {hit}")
    print("")
    print("Compose hints with KeyHint / Terminal.keyBar — one vocabulary, one separator.")
    sys.exit(1)

print("CLI copy check passed.")
PY
