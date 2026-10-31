#!/bin/bash
# Pinned framework and release tools for both command-line and Xcode builds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=2.10.1
CACHE="$ROOT/.cache/Sparkle-$VERSION"
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
if [ ! -f "$CACHE/.verified" ]; then
  mkdir -p "$ROOT/.cache"
  TEMP="$(mktemp -d "$ROOT/.cache/sparkle-download.XXXXXX")"
  trap 'rm -rf "$TEMP"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
    --output "$TEMP/Sparkle.tar.xz"
  printf '%s  %s\n' "$SHA256" "$TEMP/Sparkle.tar.xz" | shasum -a 256 -c - >&2
  mkdir "$TEMP/unpacked"
  tar -xf "$TEMP/Sparkle.tar.xz" -C "$TEMP/unpacked"
  test -d "$TEMP/unpacked/Sparkle.framework"
  test -x "$TEMP/unpacked/bin/sign_update"
  test ! -e "$CACHE"
  mv "$TEMP/unpacked" "$CACHE"
  printf '%s\n' "$SHA256" > "$CACHE/.verified"
fi
printf '%s\n' "$CACHE"
