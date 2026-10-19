"""Offline deterministic checks. No capture, model downloads or real inference."""
from __future__ import annotations
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tests._isolate  # noqa
import numpy as np
from server.config import Settings
from server.engine import Transcript
from server.pipeline import AsrWorker, _Job
from server.preprocess import StreamingAudioConditioner
from server.recorder import Recorder, _read_lines
from server.asr_stream import StreamingEngine


def wait_for(predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.005)
    raise AssertionError("Timed out waiting for worker")


class LiveEngine:
    def __init__(self, corrector=None):
        self.settings = Settings()
        self.corrector = corrector
        self.chunks = []
        self.gate = None
        self.entered = threading.Event()
        self.reset_count = 0

    def reset_stream(self):
        self.reset_count += 1

    def stream(self, uid, audio, final):
        self.chunks.append((uid, audio.copy(), final))
        self.entered.set()
        if self.gate:
            self.gate.wait(2)
        return Transcript("live words", len(audio) / 16000, 1, final)


class Corrector:
    def __init__(self, text="corrected words", fail=False):
        self.gate = threading.Event()
        self.entered = threading.Event()
        self.text, self.fail = text, fail

    def final(self, audio):
        self.entered.set()
        self.gate.wait(2)
        if self.fail:
            raise RuntimeError("test")
        return Transcript(self.text, len(audio) / 16000, 4, True)


class IncrementalTests(unittest.TestCase):
    def test_conditioning_is_chunk_invariant_and_keeps_prefix(self):
        audio = np.random.default_rng(42).normal(0, .05, 10000).astype(np.float32)
        one = StreamingAudioConditioner(Settings())(audio)
        conditioner = StreamingAudioConditioner(Settings())
        prefix = conditioner(audio[:512])
        saved = prefix.copy()
        chunks = [prefix] + [conditioner(audio[i:i+512]) for i in range(512, len(audio), 512)]
        np.testing.assert_array_equal(one, np.concatenate(chunks))
        np.testing.assert_array_equal(saved, prefix)
        conditioner.reset()
        np.testing.assert_array_equal(saved, conditioner(audio[:512]))

    def test_coalesced_partials_never_drop_or_repeat_samples(self):
        engine, events = LiveEngine(), []
        worker = AsrWorker(engine, events.append)
        audio = np.arange(100, dtype=np.float32)
        worker.start()
        try:
            worker.submit_partial(_Job(1, audio[:20], False))
            wait_for(lambda: len(events) == 1)
            # Queue replacements before allowing the worker to consume them.
            with worker._lock:
                worker.submit_partial(_Job(1, audio[:40], False))
                worker.submit_partial(_Job(1, audio[:80], False))
                worker.submit_final(_Job(1, audio, True))
            self.assertTrue(worker.drain(2))
            np.testing.assert_array_equal(np.concatenate([x[1] for x in engine.chunks]), audio)
            self.assertEqual(engine.reset_count, 1)
            self.assertEqual([x["type"] for x in events], ["partial", "final"])
        finally:
            worker.stop()

    def test_pause_suppresses_inflight_caption_and_resets_stream(self):
        engine, events = LiveEngine(), []
        engine.gate = threading.Event()
        worker = AsrWorker(engine, events.append)
        worker.start()
        try:
            worker.submit_partial(_Job(1, np.ones(32), False))
            self.assertTrue(engine.entered.wait(1))
            worker.flush()
            engine.gate.set()
            self.assertTrue(worker.drain(2))
            self.assertEqual(events, [])
            worker.submit_final(_Job(2, np.ones(64), True))
            self.assertTrue(worker.drain(2))
            self.assertEqual(engine.reset_count, 2)
            self.assertEqual(events[0]["id"], 2)
        finally:
            engine.gate.set()
            worker.stop()

    def test_adaptive_timing_backoff_is_bounded_and_optional(self):
        worker = AsrWorker(LiveEngine(), lambda _: None)
        settings = Settings()
        self.assertEqual(worker.partial_interval_ms(settings), 160)
        worker._decode_ms = 400
        self.assertEqual(worker.partial_interval_ms(settings), 500)
        worker._decode_ms = 10000
        self.assertEqual(worker.partial_interval_ms(settings), 1500)
        settings.adaptive_timing = False
        self.assertEqual(worker.partial_interval_ms(settings), 450)

    def test_sherpa_state_lives_until_final(self):
        class Stream:
            def __init__(self): self.audio, self.finished = [], False
            def accept_waveform(self, rate, audio): self.audio.extend(audio)
            def input_finished(self): self.finished = True
        class Recognizer:
            def __init__(self): self.streams = []
            def create_stream(self):
                s = Stream(); self.streams.append(s); return s
            def is_ready(self, stream): return False
            def get_result(self, stream): return "HELLO"
        engine = StreamingEngine.__new__(StreamingEngine)
        engine._recognizer, engine._cased = Recognizer(), False
        engine.reset_stream()
        engine.stream(1, np.ones(10), False)
        self.assertFalse(engine._recognizer.streams[0].finished)
        result = engine.stream(1, np.ones(20), True)
        self.assertEqual(len(engine._recognizer.streams), 1)
        self.assertTrue(engine._recognizer.streams[0].finished)
        self.assertEqual(result.duration_s, 30 / 16000)
        self.assertEqual(result.text, "hello")

    def test_correction_does_not_block_next_live_caption_and_queue_is_bounded(self):
        corrector, events = Corrector(), []
        worker = AsrWorker(LiveEngine(corrector), events.append)
        worker.start()
        try:
            worker.submit_final(_Job(1, np.ones(32), True))
            self.assertTrue(corrector.entered.wait(1))
            for uid in range(2, 7):
                worker.submit_final(_Job(uid, np.ones(32), True))
            wait_for(lambda: len(events) == 6)
            self.assertEqual(len(worker._corrections), 2)
            corrector.gate.set()
            self.assertTrue(worker.drain(2))
            self.assertEqual([x["id"] for x in events if x["type"] == "correction"], [1, 5, 6])
        finally:
            corrector.gate.set()
            worker.stop()

    def test_empty_failed_expired_and_paused_corrections_keep_live_text(self):
        for reason in ("empty", "failed", "expired", "paused"):
            with self.subTest(reason=reason):
                corrector, events = Corrector(text="" if reason == "empty" else "corrected", fail=reason == "failed"), []
                engine = LiveEngine(corrector)
                worker = AsrWorker(engine, events.append)
                worker.start()
                try:
                    worker.submit_final(_Job(1, np.ones(32), True))
                    self.assertTrue(corrector.entered.wait(1))
                    if reason == "paused": worker.flush()
                    if reason == "expired":
                        # Age is evaluated against the original threshold after inference.
                        with patch("server.pipeline.time.monotonic", return_value=time.monotonic()+20):
                            corrector.gate.set()
                            wait_for(lambda: not worker._correcting)
                    else:
                        corrector.gate.set()
                    self.assertTrue(worker.drain(2))
                    self.assertFalse(any(x["type"] == "correction" for x in events))
                    self.assertEqual(events[0]["text"], "live words")
                finally:
                    corrector.gate.set()
                    worker.stop()

    def test_recording_corrections_replace_without_duplicate_or_orphan_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            rec = Recorder(Path(tmp))
            event = dict(type="final", id=1, started_at=rec.started_at, text="original")
            rec.add_audio(np.ones(32))
            rec.add_line(event)
            rec.add_line(dict(event, type="correction", text="corrected"))
            rec.add_line(dict(event, type="correction", id=2, text="orphan"))
            self.assertEqual(rec._lines, 1)
            rec.detach()
            lines = _read_lines(rec.folder)
            self.assertEqual([x["text"] for x in lines], ["corrected"])
            self.assertNotIn("_caption_key", lines[0])


if __name__ == "__main__":
    unittest.main()
