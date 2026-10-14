#!/bin/zsh
# Keeps the CLI core's user-facing copy terse.
#
# The product's voice drops the 了 particle from command output: state lines
# read "已保存" / "已开启", not "存好了" / "开启好了". The ability forms
# (不了 / 为了 / 除了) are not that particle and stay as they are — removing
# 了 there would change the meaning, not tighten the copy.
#
# It also pins two copy rules:
# - key hints come from KeyHint / Terminal.keyBar and name the keys as the
#   keys are named — Enter, Space, ↑/↓, Esc — never the 回车 / 空格 words;
# - copy never points at an action that cannot happen: nothing sends users
#   back to `signal-light` after uninstall (the retired --expect-clean
#   check, its "查残留" suggestions), and scanning is not sold with its
#   mechanics.
#
# And it keeps the register written, not spoken: 马上 / 腾出 were the
# colloquial leftovers; the standard words are 立即 / 释放.
#
# Finally, operation headlines carry their glyph: a flow that mixes
# glyphed and bare headline lines reads as two styles, so the bare
# forms below fail the check before they can drift back in.
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

stale_hints = re.compile(r"回车|空格|↑/↓ 选择")
retired = re.compile(r"expect-clean|只扫描|不建立长连接|确认无残留|查残留")
colloquial = re.compile(r"马上|腾出")
bare_headlines = re.compile(r"^(正在检查更新|正在下载固件|跳过读设备|先停下后台服务|暂停后台服务|恢复后台服务)")
hint_hits: list[str] = []
retired_hits: list[str] = []
colloquial_hits: list[str] = []
headline_hits: list[str] = []
for path in sorted(sources.rglob("*.swift")):
    for number, line in enumerate(path.read_text().split("\n"), 1):
        if line.strip().startswith("//"):
            continue
        for match in literal.finditer(line):
            text = match.group(1)
            where = f"{path.relative_to(sources.parent.parent)}:{number}: {text}"
            if stale_hints.search(text):
                hint_hits.append(where)
            if retired.search(text):
                retired_hits.append(where)
            if colloquial.search(text):
                colloquial_hits.append(where)
            if bare_headlines.search(text):
                headline_hits.append(where)

if hint_hits:
    print("Key hints drifted away from the key names:")
    for hit in hint_hits:
        print(f"  {hit}")
    print("")
    print("Keys are Enter / Space / ↑/↓ / Esc; compose hints with KeyHint / Terminal.keyBar.")
    sys.exit(1)

if retired_hits:
    print("Copy points at something that cannot happen:")
    for hit in retired_hits:
        print(f"  {hit}")
    print("")
    print("Uninstall deletes this command; nothing may send users back to it afterwards.")
    sys.exit(1)

if colloquial_hits:
    print("Copy uses a colloquial word where a standard one belongs:")
    for hit in colloquial_hits:
        print(f"  {hit}")
    print("")
    print("Say 立即 / 释放: the product's voice is written Chinese, not spoken.")
    sys.exit(1)

if headline_hits:
    print("Progress headlines lost their operation glyph:")
    for hit in headline_hits:
        print(f"  {hit}")
    print("")
    print("Prefix them with the operation's terminal.emoji(CLIGlyph…), like the connect lines do.")
    sys.exit(1)

print("CLI copy check passed.")
PY
