#!/bin/bash
# Publish the packaged app as a GitHub release asset.
#
#   ./scripts/publish-release.sh
#
# The zip is around eighty megabytes, which is why it is a release asset rather than a file in
# the repository: git stores every version of everything forever, and a binary that changes on
# every build would make the clone larger every time somebody rebuilds.
#
# Re-running this on an existing version replaces the asset in place, so the download link on
# the website never changes and never breaks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2}' project.yml)"
TAG="v$VERSION"
ZIP="$ROOT/dist/Sunno-$VERSION-macOS-arm64.zip"
REPO="${SUNNO_REPO_SLUG:-desigrit/sunno-macos}"

[ -f "$ZIP" ] || { echo "No zip at $ZIP. Run ./scripts/package-app.sh first."; exit 1; }

# The gh CLI, found wherever it is. GH_TOKEN is unset for these calls deliberately: on a machine
# where it is injected it can belong to a different account with no push rights, and it takes
# precedence over the one gh has stored.
GH="${SUNNO_GH:-$(command -v gh || echo /Users/raunak/Library/Caches/copilot-desktop-gh-2.96.0/gh)}"
run_gh() { env -u GH_TOKEN "$GH" "$@"; }

SIZE="$(du -h "$ZIP" | cut -f1 | tr -d ' ')"
NOTES="$(cat <<NOTE
Sunno $VERSION for macOS, Apple Silicon, macOS 13.3 or later.

**[Sunno-$VERSION-macOS-arm64.zip](https://github.com/$REPO/releases/download/$TAG/Sunno-$VERSION-macOS-arm64.zip)** — $SIZE

Self-contained. It carries its own Python and speech service, so nothing needs installing.
Speech models are downloaded on first use rather than bundled, which is why this is $SIZE
rather than several gigabytes.

### Installing

1. Unzip and drag **Sunno** to Applications.
2. Open it. macOS will refuse, because this build is not notarised.
3. **System Settings → Privacy & Security**, scroll to the bottom, click **Open Anyway**.
4. Open it again.

That third step is required and there is no way around it without an Apple Developer Program
membership. macOS 15 removed the Control-click shortcut that used to skip it.

Sunno will ask for the microphone. For captioning what your Mac is playing, it also needs
**Privacy & Security → Screen & System Audio Recording**, which macOS never prompts for — you
have to switch it on there yourself and reopen the app.

### First run

Choosing a model downloads it. **\`small\` is the one to pick**: it decodes in about a third of
a second on an M1 Max, comfortably ahead of a conversation. \`large-v3\` is the most accurate on
accented speech and runs about seven times slower than that, so captions visibly trail.

The first launch after a download takes a minute or so while Core ML compiles the model for this
machine. That happens once per model.
NOTE
)"

if run_gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "==> updating $TAG"
  run_gh release edit "$TAG" --repo "$REPO" --notes "$NOTES" >/dev/null
  run_gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
else
  echo "==> creating $TAG"
  run_gh release create "$TAG" "$ZIP" --repo "$REPO" \
    --title "Sunno $VERSION for macOS" --notes "$NOTES"
fi

echo
echo "    https://github.com/$REPO/releases/tag/$TAG"
