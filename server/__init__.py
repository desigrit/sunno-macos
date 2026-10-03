"""Offline live-captioning server package."""

import os

# Disposable capture and enumeration children never load recognition libraries.
if os.environ.get("SUNNO_AUDIO_CHILD") != "1":
    from . import cuda_setup  # noqa: F401
