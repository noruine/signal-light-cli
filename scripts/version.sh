#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

level="${1:-}"
case "$level" in
    ""|patch|minor|major|none) ;;
    *)
        printf 'Unknown version level: %s\n' "$level" >&2
        printf 'Use patch, minor, major, or none.\n' >&2
        exit 2
        ;;
esac

base_version="$(git show HEAD:VERSION)"
current_version="$(cat VERSION)"

increment_number() {
    local number="$1"
    local result=""
    local digit
    local carry=1
    local index

    for ((index = ${#number} - 1; index >= 0; index--)); do
        digit="${number:index:1}"
        if [[ "$carry" == 1 ]]; then
            if [[ "$digit" == 9 ]]; then
                digit=0
            else
                digit=$((digit + 1))
                carry=0
            fi
        fi
        result="$digit$result"
    done

    if [[ "$carry" == 1 ]]; then
        result="1$result"
    fi
    printf '%s' "$result"
}

product_changed=false
if git diff --quiet HEAD -- Sources/ Makefile Package.swift; then
    :
else
    diff_status=$?
    if [[ "$diff_status" -ne 1 ]]; then
        printf 'Unable to inspect product changes.\n' >&2
        exit "$diff_status"
    fi
    product_changed=true
fi

if [[ -n "$(git ls-files --others --exclude-standard -- Sources/ Makefile Package.swift)" ]]; then
    product_changed=true
fi

if [[ "$product_changed" != true ]]; then
    if [[ "$current_version" != "$base_version" ]]; then
        printf 'VERSION changed, but no product code changed.\n' >&2
        exit 1
    fi
    printf 'No product code changes; VERSION remains %s.\n' "$base_version"
    exit 0
fi

if [[ -z "$level" ]]; then
    printf 'Product code changed; classify it and set LEVEL. See AGENTS.md.\n' >&2
    exit 2
fi

if [[ "$level" == none ]]; then
    if [[ "$current_version" != "$base_version" ]]; then
        printf 'VERSION changed, but LEVEL=none was selected.\n' >&2
        exit 1
    fi
    printf 'No public behavior change; VERSION remains %s.\n' "$base_version"
    exit 0
fi

if [[ ! "$base_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'Invalid VERSION in HEAD: %s\n' "$base_version" >&2
    exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

case "$level" in
    patch) expected_version="$major.$minor.$(increment_number "$patch")" ;;
    minor) expected_version="$major.$(increment_number "$minor").0" ;;
    major) expected_version="$(increment_number "$major").0.0" ;;
esac

if [[ "$current_version" == "$expected_version" ]]; then
    printf 'VERSION is already %s.\n' "$expected_version"
elif [[ "$current_version" == "$base_version" ]]; then
    printf '%s\n' "$expected_version" > VERSION
    printf 'Updated VERSION: %s → %s.\n' "$base_version" "$expected_version"
else
    printf 'VERSION is %s; expected %s for LEVEL=%s.\n' \
        "$current_version" "$expected_version" "$level" >&2
    exit 1
fi
