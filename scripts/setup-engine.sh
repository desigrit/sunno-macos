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

echo "==> checking"
./.venv/bin/python -c "import server.app; print('    the engine imports cleanly')"

cat <<'DONE'

Ready. The app finds this on its own; there is nothing to configure.
To run the engine by itself:

    ./.venv/bin/python -m server.app --model base

DONE
