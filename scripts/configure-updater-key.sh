#!/bin/bash
# Create or reuse the release signing key in the login Keychain. Never exports private material.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE="$(bash "$ROOT/scripts/fetch-sparkle.sh")"
ACCOUNT=com.desigrit.sunno.sparkle
CONFIG="$ROOT/config/Updater.xcconfig"
EXISTING="$(awk '/^SUNNO_SPARKLE_PUBLIC_KEY =/ {print $3}' "$CONFIG")"
if [ -n "$EXISTING" ]; then
  PUBLIC="$("$SPARKLE/bin/generate_keys" --account "$ACCOUNT" -p)"
  [ "$PUBLIC" = "$EXISTING" ] || { echo 'The Keychain key does not match the committed public key. Restore the original signing key.' >&2; exit 1; }
else
  "$SPARKLE/bin/generate_keys" --account "$ACCOUNT"
  PUBLIC="$("$SPARKLE/bin/generate_keys" --account "$ACCOUNT" -p)"
fi
python3 - "$CONFIG" "$PUBLIC" <<'PY'
import base64, pathlib, sys
config, key = sys.argv[1:]
if len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit('Invalid Ed25519 public key')
pathlib.Path(config).write_text(
    "// Public Ed25519 verification key. The private key stays in the release Mac's Keychain.\n"
    f"SUNNO_SPARKLE_PUBLIC_KEY = {key}\n")
PY
echo "Public verification key saved to $CONFIG. Commit this file with the release."
