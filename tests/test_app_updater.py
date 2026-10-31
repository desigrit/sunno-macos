"""Compile and run native updater state checks without contacting an update server."""
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if platform.system() != "Darwin":
    print("SKIP: updater state checks require macOS, AppKit and Sparkle.")
    raise SystemExit(0)

sparkle = subprocess.check_output(["bash", str(ROOT / "scripts/fetch-sparkle.sh")], text=True).strip()
sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
with tempfile.TemporaryDirectory(prefix="sunno-updater-checks-") as temp:
    app = Path(temp) / "UpdaterChecks.app"
    binary = app / "Contents/MacOS/UpdaterChecks"
    binary.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.desigrit.sunno.updaterchecks",
        "CFBundleExecutable": "UpdaterChecks", "CFBundleVersion": "1",
        "CFBundlePackageType": "APPL", "SUEnableAutomaticChecks": False,
    }))
    subprocess.run([
        "swiftc", "-swift-version", "5", "-sdk", sdk,
        "-target", "arm64-apple-macos13.3", "-F", sparkle, "-framework", "Sparkle",
        "-Xlinker", "-rpath", "-Xlinker", sparkle,
        str(ROOT / "Sunno/Services/AppUpdater.swift"),
        str(ROOT / "tests/swift/AppUpdaterChecks.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
