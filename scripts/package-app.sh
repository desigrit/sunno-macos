#!/bin/bash
# Build a self-contained Sunno.app and the zip that ships from a website.
#
#   ./scripts/package-app.sh
#
# The result runs on any Apple Silicon Mac at macOS 13.3 or later, with nothing installed:
# no Xcode, no Command Line Tools, no Python, no checkout. Model weights are NOT bundled and
# are downloaded on first use, which keeps this around 200 MB rather than several gigabytes.
#
# What it does NOT do is notarise. Without an Apple Developer Program membership the zip is
# unsigned as far as Gatekeeper is concerned, so whoever downloads it has to allow it once in
# System Settings. macOS 15 removed the Control-click shortcut that used to make that easier.
# README.md tells them how; if that step is ever a problem, the fix is 99 USD a year and a
# Developer ID certificate, not a change to this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${SUNNO_OUT:-$ROOT/dist}"
APP="$OUT/Sunno.app"
RES="$APP/Contents/Resources"
ENGINE="$RES/engine"
VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2}' project.yml)"
ZIP="$OUT/Sunno-$VERSION-macOS-arm64.zip"

# A relocatable CPython. The system one cannot be copied: /usr/bin/python3 is a stub that
# offers to install the Command Line Tools, and the Command Line Tools one is a framework
# build whose binaries link against an absolute path. python-build-standalone is built to be
# moved, which is exactly what a bundle does to it.
PY_VERSION="${SUNNO_PY_VERSION:-3.12.14}"
PY_RELEASE="${SUNNO_PY_RELEASE:-20260814}"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}/cpython-${PY_VERSION}+${PY_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PY_CACHE="${SUNNO_PY_CACHE:-$ROOT/.cache/python-${PY_VERSION}-${PY_RELEASE}}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

echo "==> Sunno $VERSION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES" "$ENGINE"

# ---------------------------------------------------------------- the app binary

echo "==> compiling the app"
swiftc \
  -swift-version 5 \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos13.3 \
  -module-name Sunno \
  -O \
  $(find Sunno -name '*.swift' | sort) \
  -o "$APP/Contents/MacOS/Sunno"

# ---------------------------------------------------------------- the speech service

echo "==> building the WhisperKit service"
# SwiftPM keeps its checkouts as bare repositories, which git refuses to read when
# safe.bareRepository is "explicit". Overridden for this command only, through the
# environment, rather than by writing to anybody's global config.
(cd whisperkit-service \
   && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
      swift build -c release >/dev/null)
mkdir -p "$ENGINE/whisperkit-service/.build/release"
cp whisperkit-service/.build/release/whisperkit-service "$ENGINE/whisperkit-service/.build/release/"

# ---------------------------------------------------------------- the python runtime

if [ ! -d "$PY_CACHE" ]; then
  echo "==> fetching a relocatable Python $PY_VERSION"
  mkdir -p "$(dirname "$PY_CACHE")"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/py.tar.gz" "$PY_URL"
  tar xzf "$tmp/py.tar.gz" -C "$tmp"
  mv "$tmp/python" "$PY_CACHE"
  rm -rf "$tmp"

  echo "==> installing the engine's dependencies"
  # Deliberately not requirements-macos.txt. That list carries faster-whisper and CTranslate2,
  # which decode on the processor and are three to five times slower than the Neural Engine
  # path this app defaults to. Shipping them would add about a hundred megabytes and a pile of
  # unsigned native libraries to be a fallback nobody would want to fall back to.
  "$PY_CACHE/bin/python3" -m pip install --quiet --upgrade pip
  "$PY_CACHE/bin/python3" -m pip install --quiet \
    numpy sounddevice soxr websockets onnxruntime sherpa-onnx huggingface_hub

  echo "==> trimming"
  rm -rf "$PY_CACHE"/lib/python*/site-packages/pip \
         "$PY_CACHE"/lib/python*/site-packages/pkg_resources \
         "$PY_CACHE"/lib/python*/{test,idlelib,tkinter,lib2to3} \
         "$PY_CACHE"/share "$PY_CACHE"/include
  find "$PY_CACHE" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
  find "$PY_CACHE" -name "*.pyc" -delete 2>/dev/null || true
fi

echo "==> copying the engine in"
cp -R "$PY_CACHE" "$ENGINE/python"
cp -R server "$ENGINE/server"
cp -R ui "$ENGINE/ui"
find "$ENGINE/server" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# The speaker embedding model, fetched if this is a clean checkout. One named file rather than
# a directory copy, because `models/` is a working directory that also accumulates benchmark
# weights, and a recursive copy would silently add a couple of hundred megabytes to a download
# whose whole argument is that it is small. Same reasoning, same single-file copy, as the
# Windows build's stage-backend.ps1.
./scripts/fetch-speaker-model.sh
mkdir -p "$ENGINE/models"
cp models/speaker-embedding-campplus-en.onnx "$ENGINE/models/"

# ---------------------------------------------------------------- metadata

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Sunno</string>
  <key>CFBundleIdentifier</key><string>com.desigrit.sunno</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Sunno</string>
  <key>CFBundleDisplayName</key><string>Sunno</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Sunno</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.3</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. Runs entirely on this Mac.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Sunno turns what it hears into captions on this Mac. Audio is never recorded to disk and never leaves this computer.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Sunno recognises speech entirely on this Mac. Nothing is sent to any server.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Sunno captions the audio your Mac is playing, such as a video call. macOS keeps system audio behind this permission. No picture of your screen is read or kept.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Sunno captions the audio your Mac is playing, such as a video call. It is transcribed on this computer and never sent anywhere.</string>
</dict>
</plist>
PLIST

echo "==> icon"
ICONSET="$OUT/Sunno.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
cp Sunno/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET"/
iconutil --convert icns "$ICONSET" --output "$RES/Sunno.icns"
rm -rf "$ICONSET"

cat > "$OUT/Sunno.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><false/>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.network.server</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
ENT

# ---------------------------------------------------------------- signing

echo "==> signing"
# Before anything is sealed. Python writes __pycache__ beside every module it imports, so a
# build whose engine was run from inside the bundle by hand would otherwise seal that bytecode
# in -- and the next run would write more of it and break the seal. The app itself sets
# PYTHONPYCACHEPREFIX so a running engine writes elsewhere; this covers the build machine.
find "$ENGINE" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
# The interpreter needs the same library-validation exception the app declares, and needs it
# in its own signature: entitlements do not inherit. Without it the hardened runtime refuses
# every native extension Python tries to load, with "mapping process and mapped file
# (non-platform) have different Team IDs" - which is what a self-signed certificate means,
# since it has no Team ID at all. This is the entitlement project.yml calls the one that most
# reliably closes the App Store door, and it is required for as long as the engine is Python.
cat > "$OUT/inner.entitlements" <<'INNER'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
</dict>
</plist>
INNER
# Every Mach-O inside the bundle, before the bundle itself. Python ships hundreds of .so
# files and an unsigned one anywhere in the tree makes the whole app fail to launch on a
# machine that did not build it. This is the macOS equivalent of the staging discipline in
# the Windows build's stage-backend.ps1, and it fails late rather than at build time, which
# is why it is done exhaustively rather than where it seems necessary.
IDENTITY="${SUNNO_IDENTITY:-$(security find-certificate -c "Sunno Local Dev" -Z ~/Library/Keychains/login.keychain-db 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}')}"
[ -z "$IDENTITY" ] && IDENTITY="-"

signed=0
while IFS= read -r macho; do
  case "$macho" in
    # Anything that loads native extensions is a loader and needs the exception. Everything
    # else only needs a valid signature.
    */bin/python*|*/whisperkit-service)
      codesign --force --sign "$IDENTITY" --options runtime \
        --entitlements "$OUT/inner.entitlements" --timestamp=none "$macho" 2>/dev/null || true
      ;;
    *)
      codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$macho" 2>/dev/null || true
      ;;
  esac
  signed=$((signed + 1))
done < <(find "$ENGINE" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) \
         -exec sh -c 'file -b "$1" | grep -q Mach-O' _ {} \; -print)
echo "    signed $signed binaries inside the bundle"

codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$OUT/Sunno.entitlements" "$APP"

codesign --verify --deep --strict "$APP" || {
  echo "    SIGNATURE INVALID - refusing to ship this bundle"
  exit 1
}
echo "    signature verifies"

# ---------------------------------------------------------------- the zip

echo "==> zipping"
rm -f "$ZIP"
# ditto rather than zip, because it preserves the resource forks and symlinks a signed bundle
# depends on. A bundle rebuilt from a plain `zip` can fail its own signature check.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "    app  $APP  ($(du -sh "$APP" | cut -f1))"
echo "    zip  $ZIP  ($(du -sh "$ZIP" | cut -f1))"
echo
echo "To publish it:  ./scripts/publish-release.sh"
