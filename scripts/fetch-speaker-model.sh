#!/bin/bash
# Fetch the speaker embedding model that speaker labelling needs.
#
#   ./scripts/fetch-speaker-model.sh
#
# WeSpeaker CAM++ trained on VoxCeleb, 512-dimensional, 28 MB, driven through sherpa-onnx by
# `server/speaker.py`. It is renamed on the way in to the name `config.py` expects, which is
# also the name the Windows package uses, so the two platforms stay diffable.
#
# It is not committed. `models/` here is a working directory, exactly as it is in the Windows
# build, where it holds this file alongside benchmark models that must never reach a package.
# Twenty-eight megabytes in git is paid by every clone forever, and this file is reproducible
# from a URL.
#
# Idempotent: re-running with the file already present and the right checksum does nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME="speaker-embedding-campplus-en.onnx"          # matches config.py's default
DEST="models/$NAME"
SHA="c46fad10b5f81e1aa4a60c162714208577093655076c5450f8c469e522ec54ef"

# The upstream release asset can be replaced. This revision contains the exact
# speaker weights shipped with the signed 1.0.94.0 app.
REVISION="70503b6968275c19ba5bdcba8da82023ee73d9d8"
URL="https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/$REVISION/wespeaker_en_voxceleb_CAM%2B%2B.onnx"

verify() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$SHA" ]; }

if verify "$DEST"; then
  echo "    already present"
  exit 0
fi

mkdir -p models
candidate="$(mktemp "models/.speaker-model.XXXXXXXX")"
trap 'rm -f "$candidate"' EXIT
echo "    downloading the pinned speaker model"
curl -fL --retry 2 --progress-bar -o "$candidate" "$URL"
if ! verify "$candidate"; then
  echo "    Speaker model checksum mismatch. Expected $SHA." >&2
  exit 1
fi
mv -f "$candidate" "$DEST"
echo "    verified"
