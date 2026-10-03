"""Bounded metadata probes and the location of the disposable native capture service."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

from .coreaudio import CaptureError

ROOT = Path(__file__).resolve().parents[1]


def helper_path() -> Path:
    candidates = [
        Path(os.environ["SUNNO_CAPTURE_HELPER"]) if os.environ.get("SUNNO_CAPTURE_HELPER") else None,
        ROOT / "capture-service" / ".build" / "release" / "capture-service",
        ROOT / "capture-service" / ".build" / "debug" / "capture-service",
    ]
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate
    raise CaptureError("capture_dependency",
                       "Sunno's audio service is missing. Reinstall Sunno or run scripts/setup-engine.sh.",
                       False)


def list_endpoints() -> list[dict]:
    try:
        result = subprocess.run([str(helper_path()), "--list"], capture_output=True,
                                timeout=2, check=True, text=True)
        devices = json.loads(result.stdout)["devices"]
        if not isinstance(devices, list):
            raise ValueError("Invalid device list")
        return devices
    except CaptureError:
        raise
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
        raise CaptureError("device_unavailable", "The audio device list is temporarily unavailable.") from exc


def default_endpoint_id(kind):
    if kind == "loopback":
        # ScreenCaptureKit captures this Mac's app audio, not a pinned output endpoint.
        return "system-audio"
    try:
        devices = list_endpoints()
        return next((d["endpoint_id"] for d in devices if d.get("is_default_input")), None)
    except CaptureError:
        # A failed metadata probe must not be confused with a changed default.
        return None
