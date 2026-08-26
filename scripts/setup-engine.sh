#!/bin/bash
# Create the Python environment the speech engine runs in.
#
#   ./scripts/setup-engine.sh
#
# Deliberately not `pip install -r requirements.txt` from the Windows project: that file does
# not resolve on macOS. pyaudiowpatch publishes no macOS wheel and no sdist, and
# nvidia-cublas-cu12 and nvidia-cudnn-cu12 publish only manylinux and win_amd64 wheels. The
# list that does resolve is requirements-macos.txt, beside this script's parent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The Command Line Tools python is enough, and is already on any Mac that can build the app.
# A Homebrew python works too; nothing here depends on which.
PYTHON="${SUNNO_PYTHON:-python3}"

if [ ! -d .venv ]; then
  echo "==> creating .venv with $("$PYTHON" -V 2>&1)"
  "$PYTHON" -m venv .venv
fi

echo "==> installing"
./.venv/bin/python -m pip install --quiet --upgrade pip
./.venv/bin/python -m pip install --quiet -r requirements-macos.txt

echo "==> fetching the speaker embedding model"
# Not committed, matching the Windows build, where `models/` is a working directory holding
# this file plus a heap of benchmark models that must not end up in a package. Twenty-eight
# megabytes of weights in git would be paid by every clone forever, and unlike the VAD model
# it is not needed to start.
#
# Without it `SpeakerIdentifier` raises and the engine prints "Speaker labelling: off", which
# is a quiet way to lose a headline feature — captions still appear, they just stop saying who
# is talking.
./scripts/fetch-speaker-model.sh

echo "==> building the WhisperKit service"
# Optional, and the engine still runs without it: CTranslate2 decodes on the processor and is
# the fallback. But on Apple Silicon that leaves the GPU and the Neural Engine idle, and the
# same speech decodes three to five times faster through Core ML, so this is built by default.
#
# SwiftPM keeps its checkouts as bare repositories, which git refuses to read when
# safe.bareRepository is set to "explicit". Overridden for this command only, through the
# environment, rather than by writing to anybody's global config.
if (cd whisperkit-service \
      && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
         swift build -c release >/dev/null 2>&1); then
  echo "    built, so Whisper will run on the Neural Engine and the GPU"
else
  echo "    could not build it; the engine will fall back to the processor"
  echo "    (run 'cd whisperkit-service && swift build -c release' to see why)"
fi

echo "==> checking"
./.venv/bin/python -c "
import server.app
from server.engine import available_engines, resolve_engine
have = available_engines()
print('    the engine imports cleanly')
print('    speech engine:', resolve_engine('auto', 'base'),
      '(neural engine)' if have['whisperkit'] else '(processor only)')
"

cat <<'DONE'

Ready. The app finds this on its own; there is nothing to configure.
To run the engine by itself:

    ./.venv/bin/python -m server.app --model base

DONE
