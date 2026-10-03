"""The real-Mac observer must check the same profile as its native host."""
import os
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch


OBSERVER = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/check-audio-switching.py"))


class ObserverProfileTests(unittest.TestCase):
    def test_default_profile_matches_native_host(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(OBSERVER["engine_identity_path"](),
                             Path.home() / "Library/Application Support/Sunno/engine.pid")

    def test_isolated_profile_uses_its_own_engine_record(self):
        profile = Path.home() / "sunno-audio-validation"
        with patch.dict(os.environ, {"Sunno_DATA_DIR": str(profile)}, clear=True):
            self.assertEqual(OBSERVER["engine_identity_path"](), profile / "engine.pid")

    def test_empty_override_keeps_the_default(self):
        with patch.dict(os.environ, {"Sunno_DATA_DIR": ""}, clear=True):
            self.assertEqual(OBSERVER["engine_identity_path"](),
                             Path.home() / "Library/Application Support/Sunno/engine.pid")


if __name__ == "__main__":
    unittest.main()
