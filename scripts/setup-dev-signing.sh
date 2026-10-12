#!/bin/zsh
#
# Create a local self-signed code signing identity for signal-light builds.
# One-time setup; idempotent on re-run.
#
# Why this exists
# ---------------
# Without a stable signing identity the binaries are ad-hoc signed, which
# produces a new cdhash on every rebuild. macOS TCC tracks Bluetooth (and
# other) permission grants for ad-hoc binaries by cdhash, so every
# `swift build` silently invalidates the grant and the next connect prompts
# again. With a real signing identity — even a local self-signed one — TCC
# tracks the certificate's designated requirement instead, so the grant
# survives rebuilds.
#
# The cert is scoped to the login keychain and never touches the system
# keychain. macOS shows one authorization prompt for the trust step; the
# Bluetooth prompt on the first connect is separate and also one-time.

set -euo pipefail

identity_name="Signal Light Dev Local"
keychain="$HOME/Library/Keychains/login.keychain-db"
store="$HOME/.signal-light/dev-signing"
cert_path="$store/cert.pem"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$identity_name"; then
    echo "Signing identity \"$identity_name\" already exists."
    exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$store"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$work_dir/key.pem" -out "$cert_path" \
    -subj "/CN=$identity_name" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$work_dir/key.pem" -in "$cert_path" \
    -out "$work_dir/identity.p12" -passout pass: >/dev/null 2>&1

security import "$work_dir/identity.p12" -k "$keychain" -P "" \
    -T /usr/bin/codesign -A >/dev/null

echo "Imported \"$identity_name\" into the login keychain."

if security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$cert_path" 2>/dev/null; then
    echo "Trusted it for code signing."
else
    echo "Trust step needs authorization — run this once, then rerun the script:"
    echo ""
    echo "  security add-trusted-cert -r trustRoot -p codeSign -k \"$keychain\" \"$cert_path\""
    echo ""
fi

echo ""
echo "Sign a build with: codesign --sign \"$identity_name\" <binary>"
