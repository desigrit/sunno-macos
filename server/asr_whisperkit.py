"""Whisper through Core ML, so the Neural Engine and the GPU do the work.

CTranslate2 runs on the processor and nothing else on macOS: there is no Metal backend and no
Neural Engine backend, and the pull request that would add one has been open since July 2026.
On an M1 Max that leaves a 32-core GPU and a 16-core Neural Engine idle while `large-v3` takes
4.7 seconds over six seconds of speech. Measured against the same clips, this path is 5.1x
faster on `base` and 3.2x on `small`, which is the difference between `small` being unusable
and being comfortable.

**Only the decode moves.** WhisperKit is Swift, so it lives in `whisperkit-service/`, a small
executable this class talks to over a pipe. Everything above stays where it is proven:
`pipeline.py`'s two-pass discipline and endpointing, `speaker.py`'s online matching, the
hallucination suppression, every constant in `config.py`. Swapping an engine should not mean
rewriting a pipeline that took a long time to tune.

Pipes rather than a socket, deliberately. A listener is a port to bind, a lifetime to manage,
and, if the bind is wrong, an open door on the network; the system audio path made that mistake
once already. A pipe has none of them, and the service exits when this process closes stdin.

**Clarity is deliberately not reported.** WhisperKit exposes `avgLogprob`, but measurement shows
its distribution differs from faster-whisper's by a factor of two to three, so the existing
mapping would read 100 where Windows reads 89 and 48 where Windows reads 0. That number tells
somebody whether they were heard, and an optimistic one is worse than none, so it stays None
until it is re-derived. `Transcript.clarity` is already optional and the UI already treats it as
such: this engine simply behaves like the streaming tier until the constant is calibrated. See
docs/MACOS-PORT.md.
"""

from __future__ import annotations

import json
import struct
import subprocess
import time
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

from .config import SAMPLE_RATE
from .engine import Transcript, Word

if TYPE_CHECKING:
    from .config import Settings


def service_binary() -> Path | None:
    """The built service, release first. Built by scripts/setup-engine.sh."""
    from .paths import INSTALL_ROOT

    root = INSTALL_ROOT / "whisperkit-service" / ".build"
    for build in ("release", "debug"):
        candidate = root / build / "whisperkit-service"
        if candidate.is_file():
            return candidate
    return None


def is_available() -> bool:
    return service_binary() is not None


def weights_root() -> Path:
    """Where the Core ML weights go.

    Not WhisperKit's default, which is ~/Documents/huggingface: several gigabytes of model
    weights do not belong in the folder somebody keeps their own files in, and nothing there
    explains what put them there. This is the same directory the rest of the app writes to, so
    it honours Sunno_DATA_DIR with everything else.
    """
    from .paths import data_dir

    return data_dir() / "whisperkit"


class _Service:
    """One short-lived service process, for the calls made outside a loaded engine."""

    def __init__(self) -> None:
        binary = service_binary()
        if binary is None:
            raise WhisperKitServiceError(
                "The WhisperKit service has not been built. Run scripts/setup-engine.sh."
            )
        self.proc = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def __enter__(self) -> "_Service":
        return self

    def __exit__(self, *exc) -> None:
        try:
            if self.proc.stdin and not self.proc.stdin.closed:
                self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            self.proc.kill()


def model_is_available(model_id: str) -> bool:
    """Whether the Core ML weights are already here.

    A different question from `models.is_available`, which answers for the CTranslate2 weights.
    Both can be true or false independently, and asking the wrong one is what put the app on
    "Loading the model" for the length of a multi-gigabyte download.
    """
    try:
        with _Service() as service:
            reply = _exchange(service.proc, {
                "op": "available",
                "model": model_id,
                "download_base": str(weights_root()),
            })
        return bool(reply.get("available"))
    except Exception:
        return False


def download_model(model_id: str, on_progress=None) -> None:
    """Fetch the Core ML weights, reporting progress in the shape app.py already emits."""
    weights_root().mkdir(parents=True, exist_ok=True)
    with _Service() as service:
        _exchange(
            service.proc,
            {"op": "prepare", "model": model_id, "download_base": str(weights_root())},
            on_progress=on_progress,
        )


def _read_frame(proc) -> dict:
    header = _read_exactly(proc, 4)
    (size,) = struct.unpack("<I", header)
    return json.loads(_read_exactly(proc, size))


def _read_exactly(proc, count: int) -> bytes:
    """A pipe hands back what is buffered, so one read is not a frame."""
    chunks: list[bytes] = []
    remaining = count
    while remaining > 0:
        chunk = proc.stdout.read(remaining)
        if not chunk:
            raise WhisperKitServiceError("the speech service closed mid-reply")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _exchange(proc, header: dict, audio=None, on_progress=None) -> dict:
    """Send one request and read frames until a terminal one arrives.

    A download reports itself as it goes, so anything carrying `progress` is an update rather
    than an answer, and the loop keeps reading.
    """
    if proc.poll() is not None:
        raise WhisperKitServiceError("the speech service exited")
    if audio is not None:
        header = {**header, "samples": int(audio.size)}

    body = json.dumps(header).encode("utf-8")
    try:
        proc.stdin.write(struct.pack("<I", len(body)) + body)
        if audio is not None:
            proc.stdin.write(np.ascontiguousarray(audio, dtype="<f4").tobytes())
        proc.stdin.flush()
    except (BrokenPipeError, OSError) as exc:
        raise WhisperKitServiceError("the speech service stopped listening") from exc

    while True:
        reply = _read_frame(proc)
        if reply.get("progress") is None:
            if not reply.get("ok"):
                raise WhisperKitServiceError(reply.get("error", "the service reported a failure"))
            return reply
        if on_progress is not None:
            fraction = float(reply["progress"])
            on_progress(int(fraction * 1000), 1000)


class WhisperKitServiceError(RuntimeError):
    """The service could not be started or stopped answering."""


class WhisperKitEngine:
    """One loaded model, decoding both passes, exactly as CTranslate2Engine does.

    The two passes differ only in what is asked for: the provisional one skips word timestamps
    because the text is replaced moments later and the timings are never read, and the final one
    asks for them because that is what the per-word shading needs.
    """

    def __init__(self, settings: "Settings") -> None:
        self.settings = settings
        binary = service_binary()
        if binary is None:
            raise WhisperKitServiceError(
                "The WhisperKit service has not been built. Run scripts/setup-engine.sh."
            )

        self._proc = subprocess.Popen(
            [str(binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            # stderr is left attached so a Core ML failure is visible where the engine's other
            # output goes, rather than disappearing into a pipe nobody drains.
        )

        try:
            reply = self._call({
                "op": "load",
                "model": settings.model_size,
                "download_base": str(weights_root()),
            })
        except Exception:
            self.close()
            raise
        self.compute_units = reply.get("compute_units", "unknown")
        # Per stage, because "is it using the Neural Engine" has three answers and they are
        # not the same one. Printed at startup so a diagnostics report says which part of the
        # chip did the work rather than leaving it to be assumed.
        self.compute_detail = reply.get("compute_detail") or {}
        if self.compute_detail:
            stages = ", ".join(f"{k} {v}" for k, v in sorted(self.compute_detail.items()))
            print(f"Whisper compute: {stages}", flush=True)

    # --- wire ----------------------------------------------------------

    def _call(self, header: dict, audio: np.ndarray | None = None) -> dict:
        return _exchange(self._proc, header, audio)

    # --- decoding ------------------------------------------------------

    def _run(self, audio: np.ndarray, want_words: bool, is_final: bool) -> Transcript:
        started = time.perf_counter()
        reply = self._call(
            {
                "op": "transcribe",
                "language": self.settings.language,
                "word_timestamps": want_words,
                # Temperature fallback belongs to the final pass alone: provisional text is
                # replaced moments later and a retry would blow its latency budget.
                "temperature": 0.0,
                # The hallucination suppression, from the same constants asr.py hands
                # faster-whisper. Leaving them off is not a small difference: Whisper decodes
                # noise into invented sentences and runs to the token limit doing it, and two
                # seconds of noise took 110 seconds on large-v3 before these were passed.
                "no_speech_threshold": self.settings.no_speech_threshold,
                "log_prob_threshold": self.settings.log_prob_threshold,
                "compression_ratio_threshold": self.settings.compression_ratio_threshold,
            },
            audio,
        )
        if not reply.get("ok"):
            raise WhisperKitServiceError(reply.get("error", "decode failed"))

        # The service already sends start and end for every word; they were being dropped
        # here. They are what lets a saved recording line up with its audio, so a reader can
        # find the moment a sentence was said rather than scrubbing for it.
        words = [
            Word(text=w["word"], probability=float(w["probability"]),
                 start_s=None if w.get("start") is None else float(w["start"]),
                 end_s=None if w.get("end") is None else float(w["end"]))
            for w in (reply.get("words") or [])
        ]
        return Transcript(
            text=(reply.get("text") or "").strip(),
            duration_s=float(audio.size) / SAMPLE_RATE,
            latency_ms=(time.perf_counter() - started) * 1000,
            is_final=is_final,
            # See the module docstring: parked until the mapping is re-derived.
            clarity=None,
            words=words,
        )

    def partial(self, audio: np.ndarray) -> Transcript:
        return self._run(audio, want_words=False, is_final=False)

    def final(self, audio: np.ndarray) -> Transcript:
        return self._run(audio, want_words=True, is_final=True)

    def warmup(self) -> float:
        """Exercise the real decode path once, so the first-use cost lands at startup.

        Core ML compiles and caches a model the first time it runs on a given compute unit, and
        that cost is seconds rather than milliseconds. Paying it here puts it behind the loading
        indicator instead of behind somebody's first sentence.
        """
        started = time.perf_counter()
        rng = np.random.default_rng(0)
        audio = (rng.standard_normal(SAMPLE_RATE * 2) * 0.01).astype(np.float32)
        self.final(audio)
        return (time.perf_counter() - started) * 1000

    # --- lifecycle -----------------------------------------------------

    def add_context(self, text: str) -> None:
        """Accepted and ignored, for now.

        CTranslate2Engine feeds recent text back as Whisper's initial_prompt. WhisperKit takes
        prompt tokens rather than a string, so carrying this across means tokenising on the
        Swift side; it is left out rather than half-done, and costs a little accuracy on
        continued sentences.
        """

    def clear_context(self) -> None:
        pass

    def close(self) -> None:
        proc = getattr(self, "_proc", None)
        if proc is None:
            return
        try:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.close()   # the service exits on end of stdin
            proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            proc.kill()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass
