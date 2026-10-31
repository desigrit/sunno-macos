#!/bin/bash
# Sign the archive and feed using the release secret or a local Keychain key.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="${1:?Pass the packaged Sunno ZIP}"
SPARKLE="$(bash "$ROOT/scripts/fetch-sparkle.sh")"
ACCOUNT=com.desigrit.sunno.sparkle
EXPECTED="$(awk '/^SUNNO_SPARKLE_PUBLIC_KEY =/ {print $3}' "$ROOT/config/Updater.xcconfig")"
if [ -n "${SUNNO_SPARKLE_PRIVATE_KEY:-}" ]; then
  # Use stdin so the private seed never appears in process arguments or on disk.
  sign_update() {
    printf '%s\n' "$SUNNO_SPARKLE_PRIVATE_KEY" | "$SPARKLE/bin/sign_update" --ed-key-file - "$@"
  }
  PUBLIC="$EXPECTED"
else
  PUBLIC="$("$SPARKLE/bin/generate_keys" --account "$ACCOUNT" -p)"
  [ -n "$EXPECTED" ] && [ "$PUBLIC" = "$EXPECTED" ] || {
    echo 'Signing key does not match config/Updater.xcconfig. Restore the original release key.' >&2; exit 1;
  }
  sign_update() { "$SPARKLE/bin/sign_update" --account "$ACCOUNT" "$@"; }
fi
SIGNATURE="$(sign_update -p "$ZIP")"
sign_update --verify "$ZIP" "$SIGNATURE"
TEMP="$(mktemp -d "$(dirname "$ZIP")/appcast.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
python3 "$ROOT/scripts/create_appcast.py" "$ZIP" "$SIGNATURE" "$PUBLIC" "$TEMP/appcast.xml"
sign_update "$TEMP/appcast.xml"
sign_update --verify "$TEMP/appcast.xml"
# Independently verify using the public key shipped to users, including in CI.
python3 "$ROOT/scripts/verify_release.py" "$ZIP" "$TEMP/appcast.xml" "$PUBLIC"
mv "$TEMP/appcast.xml" "$(dirname "$ZIP")/appcast.xml"
echo "Signed feed: $(dirname "$ZIP")/appcast.xml"
