#!/bin/bash
# Sign the archive and feed with the same Keychain key embedded in the app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="${1:?Pass the packaged Sunno ZIP}"
SPARKLE="$(bash "$ROOT/scripts/fetch-sparkle.sh")"
ACCOUNT=com.desigrit.sunno.sparkle
EXPECTED="$(awk '/^SUNNO_SPARKLE_PUBLIC_KEY =/ {print $3}' "$ROOT/config/Updater.xcconfig")"
PUBLIC="$("$SPARKLE/bin/generate_keys" --account "$ACCOUNT" -p)"
[ -n "$EXPECTED" ] && [ "$PUBLIC" = "$EXPECTED" ] || {
  echo 'Signing key does not match config/Updater.xcconfig. Restore the original release key.' >&2; exit 1;
}
SIGNATURE="$("$SPARKLE/bin/sign_update" --account "$ACCOUNT" -p "$ZIP")"
"$SPARKLE/bin/sign_update" --account "$ACCOUNT" --verify "$ZIP" "$SIGNATURE"
TEMP="$(mktemp -d "$(dirname "$ZIP")/appcast.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
python3 "$ROOT/scripts/create_appcast.py" "$ZIP" "$SIGNATURE" "$PUBLIC" "$TEMP/appcast.xml"
"$SPARKLE/bin/sign_update" --account "$ACCOUNT" "$TEMP/appcast.xml"
"$SPARKLE/bin/sign_update" --account "$ACCOUNT" --verify "$TEMP/appcast.xml"
mv "$TEMP/appcast.xml" "$(dirname "$ZIP")/appcast.xml"
echo "Signed feed: $(dirname "$ZIP")/appcast.xml"
