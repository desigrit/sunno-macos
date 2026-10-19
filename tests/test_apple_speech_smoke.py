"""Opt-in real SpeechAnalyzer check using generated speech, never microphone audio.

SUNNO_TEST_APPLE_SPEECH=1 python tests/test_apple_speech_smoke.py
Requires Apple's English assets to be installed already; does not download them.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import wave

import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server.asr_apple import AppleSpeechEngine, NATIVE_MODEL
from server.config import Settings
from server.preprocess import StreamingAudioConditioner


@unittest.skipUnless(os.environ.get("SUNNO_TEST_APPLE_SPEECH") == "1", "opt-in native speech check")
class NativeSpeechSmoke(unittest.TestCase):
    def test_generated_speech_streams_then_finalizes_and_resets(self):
        with tempfile.TemporaryDirectory(prefix="sunno-synthetic-speech-") as temp:
            source, wav = Path(temp) / "speech.aiff", Path(temp) / "speech.wav"
            subprocess.run(["say", "-v", "Samantha", "-o", str(source),
                            "These captions are running entirely on this computer. "
                            "Tomorrow we will compare the results with another speech model."], check=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                            str(source), str(wav)], check=True, capture_output=True)
            with wave.open(str(wav)) as handle:
                audio = np.frombuffer(handle.readframes(handle.getnframes()), dtype="<i2").astype(np.float32) / 32768
            audio = np.concatenate((audio, np.zeros(8000, np.float32)))
            settings = Settings(model_size=NATIVE_MODEL)
            engine = AppleSpeechEngine(settings)
            try:
                engine.warmup()
                conditioner = StreamingAudioConditioner(settings)
                partials = []
                for start in range(0, len(audio), 5120):
                    result = engine.stream(1, conditioner(audio[start:start+5120]), False)
                    if result.text:
                        partials.append(result.text)
                    time.sleep(.32)
                final = engine.stream(1, np.zeros(0, np.float32), True)
                self.assertTrue(partials, "No provisional captions arrived before finalization")
                self.assertIn("captions", final.text.lower())
                self.assertIn("computer", final.text.lower())
                self.assertAlmostEqual(final.duration_s, len(audio) / 16000)
                engine.reset_stream()
                silent = engine.stream(2, np.zeros(16000, np.float32), True)
                self.assertNotIn("captions", silent.text.lower(), "Previous phrase leaked across reset")
                print("PASS native provisional, final and reset paths with synthetic speech")
            finally:
                engine.close()


if __name__ == "__main__":
    unittest.main()
