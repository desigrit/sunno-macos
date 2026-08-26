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

# The upstream tag really is spelt "recongition". Do not correct it: it is the release name,
# and fixing the typo produces a 404.
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_CAM++.onnx"

verify() { [ -f "$DEST" ] && [ "$(shasum -a 256 "$DEST" | cut -d' ' -f1)" = "$SHA" ]; }

if verify; then
  echo "    already present"
  exit 0
fi

mkdir -p models
echo "    downloading 28 MB from k2-fsa/sherpa-onnx"
curl -fL --progress-bar -o "$DEST.part" "$URL"
mv "$DEST.part" "$DEST"

if verify; then
  echo "    verified"
else
  # A partial download that gets used is worse than one that fails here: the extractor would
  # either throw somewhere far away or, worse, load and return quietly meaningless embeddings.
  echo "    checksum mismatch — got $(shasum -a 256 "$DEST" | cut -d' ' -f1)"
  echo "    expected $SHA"
  rm -f "$DEST"
  exit 1
fi
