#!/bin/bash
# Publish a complete signed release. Never replace binaries in an existing release.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(awk -F'"' '/SUNNO_RELEASE_VERSION:/ {print $2}' project.yml)"
TAG="v$VERSION"
ZIP="$ROOT/dist/Sunno-$VERSION-macOS-arm64.zip"
REPO=desigrit/sunno-macos
[ -f "$ZIP" ] || { echo "Run scripts/package-app.sh first." >&2; exit 1; }
GH="${SUNNO_GH:-$(command -v gh)}"
bash "$ROOT/scripts/create-appcast.sh" "$ZIP"

if "$GH" release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists. Increment the version instead of replacing a published update." >&2
  exit 1
fi
# Requiring the source tag avoids creating a release from an unrelated default-branch commit.
git rev-parse --verify "refs/tags/$TAG" >/dev/null
test "$(git rev-list -n 1 "$TAG")" = "$(git rev-parse HEAD)"
test -z "$(git status --porcelain --untracked-files=normal)" || {
  echo 'Commit the release sources before publishing.' >&2; exit 1;
}
NOTES="$(mktemp "$ROOT/dist/release-notes.XXXXXX")"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<NOTE
Sunno $VERSION for Apple silicon, macOS 13.3 or later.

Download Sunno-$VERSION-macOS-arm64.zip, unzip it, and move Sunno to Applications.
For a build that macOS does not recognise, use System Settings > Privacy & Security > Open Anyway.

Updates are available in Settings > Updates and the Sunno menu. Downloads and update metadata
are verified before installation. Speech recognition stays on your Mac.

This build includes its engine. Speech models download when selected.
NOTE
# Upload both assets to a draft first so the live feed never points at a missing ZIP.
"$GH" release create "$TAG" "$ZIP" "$ROOT/dist/appcast.xml" --repo "$REPO" \
  --verify-tag --draft --title "Sunno $VERSION for macOS" --notes-file "$NOTES"
"$GH" release edit "$TAG" --repo "$REPO" --draft=false --latest
echo "https://github.com/$REPO/releases/tag/$TAG"
