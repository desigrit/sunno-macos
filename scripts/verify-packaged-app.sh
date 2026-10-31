#!/bin/bash
# Exercise the distributed runtime, including the archive after extraction.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(awk -F'"' '/SUNNO_RELEASE_VERSION:/ {print $2}' project.yml)"
OUT="${SUNNO_OUT:-$ROOT/dist}"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
ditto -x -k "$OUT/Sunno-$VERSION-macOS-arm64.zip" "$TEMP"
APP="$TEMP/Sunno.app"
ENGINE="$APP/Contents/Resources/engine"
codesign --verify --deep --strict "$APP"
python3 "$ROOT/scripts/verify_macos_compatibility.py" "$APP"
echo 'Checking native app and helper architectures'
for BINARY in "$APP/Contents/MacOS/Sunno" \
              "$ENGINE/capture-service/.build/release/capture-service" \
              "$ENGINE/apple-speech-service/.build/release/apple-speech-service" \
              "$ENGINE/whisperkit-service/.build/release/whisperkit-service" \
              "$ENGINE/python/bin/python3"; do
  lipo -verify_arch arm64 "$BINARY"
  codesign --verify --strict "$BINARY"
done
echo 'Loading the packaged speech runtime'
(cd "$ENGINE"
PYTHONDONTWRITEBYTECODE=1 "$ENGINE/python/bin/python3" -u - <<'PY'
import importlib
import platform
assert platform.machine() == 'arm64'
for name in ('numpy', 'av', 'huggingface_hub', 'onnxruntime', 'sherpa_onnx', 'sounddevice', 'soxr', 'websockets'):
    print('Loading', name, flush=True)
    importlib.import_module(name)
import onnxruntime
assert onnxruntime.get_available_providers()
print('Loading the packaged Sunno engine', flush=True)
import server.app
from server.engine import available_engines, resolve_engine
assert available_engines()['whisperkit']
assert resolve_engine('auto', 'base') == 'whisperkit'
print('Loading the bundled VAD and speaker models together', flush=True)
import numpy as np
from pathlib import Path
from server.vad import StreamingSileroVAD
from server.speaker import SpeakerIdentifier
vad = StreamingSileroVAD()
assert 0 <= vad(np.zeros(512, dtype=np.float32)) <= 1
speaker = SpeakerIdentifier(Path('models/speaker-embedding-campplus-en.onnx'), num_threads=1)
assert speaker._extractor.dim > 0
assert 0 <= vad(np.zeros(512, dtype=np.float32)) <= 1
print('Packaged Python and all speech engine dependencies loaded on arm64')
PY
)
PUBLIC="$(awk '/^SUNNO_SPARKLE_PUBLIC_KEY =/ {print $3}' config/Updater.xcconfig)"
python3 scripts/verify_release.py "$OUT/Sunno-$VERSION-macOS-arm64.zip" "$OUT/appcast.xml" "$PUBLIC"
# Launching imports must not change the signed bundle.
codesign --verify --deep --strict "$APP"
