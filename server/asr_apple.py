"""On-device Apple SpeechAnalyzer, with optional independent Whisper corrections."""
from __future__ import annotations

import json
import os
import platform
import select
import struct
import subprocess
import time
from dataclasses import replace
from pathlib import Path

import numpy as np

from .config import SAMPLE_RATE, Settings
from .engine import Transcript

NATIVE_MODEL = "apple-speech"
HYBRID_MODEL = "apple-speech-whisper"


def is_apple_model(model: str) -> bool:
    return model in (NATIVE_MODEL, HYBRID_MODEL)


def service_binary() -> Path | None:
    from .paths import INSTALL_ROOT
    if platform.system() != "Darwin":
        return None
    for build in ("release", "debug"):
        path = INSTALL_ROOT / "apple-speech-service" / ".build" / build / "apple-speech-service"
        if path.is_file():
            return path
    return None


def is_supported_os() -> bool:
    return platform.system() == "Darwin" and int(platform.mac_ver()[0].split(".")[0] or 0) >= 26


class SpeechService:
    def __init__(self):
        binary = service_binary()
        if not is_supported_os() or binary is None:
            raise RuntimeError("Apple Speech requires macOS 26 or later and the native speech service.")
        self.proc = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, bufsize=0)

    def call(self, op: str, audio=None, final=False, timeout=20.0, locale=None):
        payload = b"" if audio is None else np.asarray(audio, dtype="<f4").tobytes()
        header = json.dumps({"op": op, "samples": len(payload) // 4, "final": final, "locale": locale}).encode()
        deadline = time.monotonic() + timeout
        try:
            # Bound both writes and reads. A hung helper cannot wedge the worker forever.
            packet = memoryview(struct.pack("<I", len(header)) + header + payload)
            while packet:
                left = deadline - time.monotonic()
                if left <= 0 or not select.select([], [self.proc.stdin], [], left)[1]:
                    raise TimeoutError()
                sent = os.write(self.proc.stdin.fileno(), packet[:4096])
                packet = packet[sent:]

            def read(count):
                data = bytearray()
                while len(data) < count:
                    left = deadline - time.monotonic()
                    if left <= 0 or not select.select([self.proc.stdout], [], [], left)[0]:
                        raise TimeoutError()
                    chunk = os.read(self.proc.stdout.fileno(), count - len(data))
                    if not chunk:
                        raise RuntimeError("Apple Speech stopped unexpectedly.")
                    data.extend(chunk)
                return data

            size = struct.unpack("<I", read(4))[0]
            if size > 1024 * 1024:
                raise RuntimeError("Invalid speech response.")
            response = json.loads(read(size))
            if not response.get("ok"):
                raise RuntimeError(response.get("error", "Apple Speech is unavailable."))
            return response
        except TimeoutError:
            self.close()
            raise RuntimeError("Apple Speech took too long to respond.") from None
        except Exception:
            self.close()
            raise

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=1)
        for handle in (self.proc.stdin, self.proc.stdout):
            if handle and not handle.closed:
                handle.close()


def supported_locales(model_id):
    from .spoken_language import root_language, whisper_codes
    service = SpeechService()
    try:
        inventory = service.call("locales")
        locales = sorted(set(inventory["supported"]))
        if model_id == HYBRID_MODEL:
            locales = [c for c in locales if root_language(c) in whisper_codes("large-v3")]
        return locales
    finally:
        service.close()


def prepare_locale(locale):
    service = SpeechService()
    try:
        if not service.call("prepare", timeout=600, locale=locale).get("available"):
            raise RuntimeError("The speech language is not ready. Select it again to retry setup.")
    finally:
        service.close()


def model_is_available(model_id: str, language="en") -> bool:
    if not is_supported_os() or service_binary() is None:
        return False
    service = SpeechService()
    try:
        from .spoken_language import resolve
        locale = resolve(language, supported_locales(model_id))
        available = service.call("status", locale=locale, timeout=10).get("available", False)
    except Exception:
        return False
    finally:
        service.close()
    if model_id == HYBRID_MODEL and available:
        from .asr_whisperkit import model_is_available as whisper_available
        available = whisper_available("large-v3")
    return bool(available)


def download_model(model_id: str, on_progress=None, language="en"):
    from .spoken_language import resolve
    prepare_locale(resolve(language, supported_locales(model_id)))
    if model_id == HYBRID_MODEL:
        from .asr_whisperkit import download_model as download_whisper
        download_whisper("large-v3", on_progress)
    if on_progress:
        on_progress(1, 1)


class AppleSpeechEngine:
    def __init__(self, settings: Settings):
        self._locale = settings.language or "en-US"
        self.settings = settings
        self._service = None
        self._id = None
        self._samples = 0
        self.corrector = None
        self.create_corrector = self._create_corrector if settings.model_size == HYBRID_MODEL else None

    def set_language(self, language):
        self._locale = language

    def _create_corrector(self, cancelled):
        from .asr_whisperkit import WhisperKitEngine

        from .spoken_language import root_language
        return WhisperKitEngine(replace(self.settings, model_size="large-v3", language=root_language(self._locale),
                                        use_context_prompt=False),
                                cancelled=cancelled)

    def reset_stream(self):
        if self._service is not None:
            try:
                self._service.call("reset", timeout=3)
            except Exception:
                self._service.close()
                self._service = None
        self._id = None
        self._samples = 0

    def stream(self, utterance_id, audio, is_final):
        start = time.perf_counter()
        try:
            if self._service is None or self._service.proc.poll() is not None:
                self._service = SpeechService()
                self._id = None
            if self._id != utterance_id:
                self._service.call("begin", locale=self._locale)
                self._id = utterance_id
                self._samples = 0
            response = self._service.call("push", audio, final=is_final)
            self._samples += len(audio)
            result = Transcript(response.get("text", ""), self._samples / SAMPLE_RATE,
                                (time.perf_counter() - start) * 1000, is_final)
            if is_final:
                self._id = None
            return result
        except Exception:
            self.close()
            raise

    def partial(self, audio):
        raise RuntimeError("Apple Speech requires incremental audio.")

    def final(self, audio):
        self.reset_stream()
        return self.stream(0, audio, True)

    def warmup(self):
        start = time.perf_counter()
        self._service = SpeechService()
        self._service.call("begin", locale=self._locale)
        self.reset_stream()
        return (time.perf_counter() - start) * 1000

    def close(self):
        if self._service is not None:
            self._service.close()
        self._service = None
        self._id = None
