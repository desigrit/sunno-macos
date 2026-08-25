#!/bin/bash
# Capture the README screenshots from a running copy of the app.
#
#   ./scripts/capture-screenshots.sh
#
# Needs the screen unlocked and awake. A locked Mac has no rendered windows to photograph, and
# screencapture will cheerfully hand back the desktop picture instead of telling you so.
#
# Region capture and window capture both need a screen recording grant that the shell usually
# does not have, so this takes the whole screen — which /usr/sbin/screencapture is entitled to
# do — and crops to the window afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
APP="${1:-$ROOT/dist/Sunno.app}"
mkdir -p "$OUT"

command -v swift >/dev/null || export DEVELOPER_DIR=/Library/Developer/CommandLineTools

if python3 -c "
import subprocess,sys
out = subprocess.run(['ioreg','-n','Root','-d1','-a'],capture_output=True,text=True).stdout
sys.exit(0 if 'CGSSessionScreenIsLocked' in out else 1)"; then
  echo "The screen is locked. Unlock it and run this again — a locked Mac renders no windows,"
  echo "and you would get a picture of the desktop instead."
  exit 1
fi

HELPER="$(mktemp -d)/shot.swift"
cat > "$HELPER" <<'SWIFT'
import AppKit
import Foundation

// Finds Sunno's window, crops the given full-screen capture to it, writes a PNG.
let a = CommandLine.arguments
guard a.count >= 3 else { exit(2) }

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] else { exit(2) }
var frame: CGRect?
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Sunno" {
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.height > 200 else { continue }
    frame = r
    break
}
guard let f = frame else {
    FileHandle.standardError.write(Data("Sunno has no visible window\n".utf8)); exit(1)
}

guard let src = NSImage(contentsOfFile: a[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let screen = NSScreen.main else { exit(2) }
let scale = CGFloat(cg.width) / screen.frame.width
let crop = CGRect(x: f.origin.x * scale, y: f.origin.y * scale,
                  width: f.width * scale, height: f.height * scale)
guard let out = cg.cropping(to: crop),
      let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
else { exit(2) }
try png.write(to: URL(fileURLWithPath: a[2]))
print("  \(out.width)x\(out.height)  \((a[2] as NSString).lastPathComponent)")
SWIFT

shoot() {  # shoot <name> <prompt>
  echo
  echo "  $2"
  read -r -p "  press return when ready... " _
  local full; full="$(mktemp -t sunno-full).png"
  screencapture -x -t png "$full"
  swift "$HELPER" "$full" "$OUT/$1.png" || true
  rm -f "$full"
}

open -a "$APP"
sleep 3
osascript -e 'tell application id "com.desigrit.sunno" to activate' >/dev/null 2>&1 || true
sleep 1

echo "==> capturing to docs/screenshots"
shoot main       "Record a little speech so there are captions on screen, with speaker names."
shoot models     "Open Settings and expand the speech model list."
shoot compact    "Switch to compact mode."

echo
echo "Done. Check them, then reference them from README.md."
