"""Compile and run real Swift input-state and transcript recovery checks on macOS."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if sys.platform != "darwin" or shutil.which("swiftc") is None:
    print("SKIP: Swift input-state checks require a macOS Swift toolchain.")
    raise SystemExit(0)
sources = ["Sunno/Models/InputSwitch.swift", "Sunno/Protocol/Events.swift",
           "Sunno/Models/TranscriptStore.swift", "Sunno/Models/AudioMeter.swift",
           "Sunno/Models/SessionClock.swift", "Sunno/Theme.swift",
           "tests/swift/InputSwitch.swift"]
sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
with tempfile.TemporaryDirectory(prefix="sunno-input-tests-") as directory:
    executable = Path(directory) / "input-switch"
    subprocess.run(["swiftc", "-swift-version", "5", "-sdk", sdk,
                    "-target", "arm64-apple-macos13.3", *[str(ROOT / p) for p in sources],
                    "-o", str(executable)], check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=15)
