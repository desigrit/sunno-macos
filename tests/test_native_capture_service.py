"""Native conversion and metadata checks. No microphone capture or saved audio."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "capture-service/.build/release/capture-service"

if sys.platform != "darwin":
    print("SKIP: native Core Audio and ScreenCaptureKit checks require macOS.")
    raise SystemExit(0)
if not HELPER.is_file():
    raise SystemExit("Build capture-service before running its native checks.")


def run(*arguments):
    result = subprocess.run([str(HELPER), *arguments], capture_output=True,
                            text=True, timeout=8, check=True)
    return [json.loads(line) for line in result.stdout.splitlines()]


conversion = run("--self-test")[-1]
assert conversion["checks"] == 3 and conversion["frames"] >= 3
print("PASS native 48 kHz, 44.1 kHz and 96 kHz stereo-to-mono conversion and format changes")
catalog = run("--list")[-1]["devices"]
assert all(device.get("endpoint_id") for device in catalog)
assert len({device["endpoint_id"] for device in catalog}) == len(catalog)
print("PASS native endpoint enumeration with stable unique UIDs")
selection = json.dumps({"kind": "loopback", "follow_default": True})
probe = run(selection, "--probe")[-1]
assert probe["type"] == "ready" and probe["probe"]
assert probe["target"]["endpoint_id"] == "system-audio"
print("PASS paused system-audio selection is metadata only, without opening capture")
