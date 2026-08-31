"""Compile and run the Swift state-machine checks.

Covers the model switcher and the recording controller, including the paths a code review
asked about: a model that downloads and then will not load, a fallback that also dies, a
second pick while one is in flight, and an engine that disappears mid-recording.

Skips loudly without a Swift toolchain, the way test_theme_parity.py does.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

SOURCES = [
    "Sunno/Models/TranscriptStore.swift",
    "Sunno/Models/AudioMeter.swift",
    "Sunno/Models/SessionClock.swift",
    "Sunno/Models/ModelSwitch.swift",
    "Sunno/Models/RecordingController.swift",
    "Sunno/Protocol/Events.swift",
    "Sunno/Theme.swift",
    "tests/swift/StateMachines.swift",
]

if shutil.which("swiftc") is None:
    print("SKIP: no swiftc on PATH, so the state-machine checks did not run.")
    print("  They guard the model switcher against stranding a user on a model that will not")
    print("  load, and the recording pill against claiming to record into a dead engine.")
    raise SystemExit(0)

sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True)
if sdk.returncode != 0:
    print("SKIP: no SDK, so the state-machine checks did not run.")
    raise SystemExit(0)

with tempfile.TemporaryDirectory() as tmp:
    binary = Path(tmp) / "state-machines"
    build = subprocess.run(
        ["swiftc", "-swift-version", "5", "-sdk", sdk.stdout.strip(),
         "-target", "arm64-apple-macos13.3",
         *[str(REPO / s) for s in SOURCES], "-o", str(binary)],
        capture_output=True, text=True,
    )
    if build.returncode != 0:
        print("FAILED to compile the checks:\n" + build.stderr[-2500:])
        raise SystemExit(1)

    run = subprocess.run([str(binary)], capture_output=True, text=True)
    print(run.stdout.rstrip())
    if run.returncode != 0:
        print(run.stderr.rstrip())
        raise SystemExit(1)
