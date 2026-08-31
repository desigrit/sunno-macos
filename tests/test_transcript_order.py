"""Compile and run the Swift transcript-ordering checks.

Swift, because the bug being guarded is in the Swift client's line identity and nothing in
Python can see it. Skips loudly rather than failing when there is no compiler, matching
test_theme_parity.py: a contributor without the toolchain should be told what they are not
running, not handed a red suite.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

SOURCES = [
    "Sunno/Models/TranscriptStore.swift",
    "Sunno/Models/AudioMeter.swift",
    "Sunno/Models/SessionClock.swift",
    "Sunno/Protocol/Events.swift",
    "Sunno/Theme.swift",
    "tests/swift/TranscriptOrder.swift",
]

if shutil.which("swiftc") is None:
    print("SKIP: no swiftc on PATH, so the transcript ordering checks did not run.")
    print("  They guard the client's line identity across an engine restart, which is what")
    print("  stops new speech overwriting the top of the transcript when the capture source")
    print("  changes. Install the Command Line Tools to run them.")
    raise SystemExit(0)

sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True)
if sdk.returncode != 0:
    print("SKIP: no SDK, so the transcript ordering checks did not run.")
    raise SystemExit(0)

with tempfile.TemporaryDirectory() as tmp:
    binary = Path(tmp) / "transcript-order"
    build = subprocess.run(
        ["swiftc", "-swift-version", "5", "-sdk", sdk.stdout.strip(),
         "-target", "arm64-apple-macos13.3",
         *[str(REPO / s) for s in SOURCES], "-o", str(binary)],
        capture_output=True, text=True,
    )
    if build.returncode != 0:
        print("FAILED to compile the checks:\n" + build.stderr[-2000:])
        raise SystemExit(1)

    run = subprocess.run([str(binary)], capture_output=True, text=True)
    print(run.stdout.rstrip())
    if run.returncode != 0:
        print(run.stderr.rstrip())
        raise SystemExit(1)
