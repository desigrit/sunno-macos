"""Run the actual desktop entry point with capture paused and no cached model."""
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DesktopStartupTests(unittest.TestCase):
    def test_desktop_launch_starts_and_parent_eof_stops_it(self):
        with tempfile.TemporaryDirectory(prefix="sunno-startup-test-") as directory:
            environment = dict(os.environ)
            environment.update({
                "Sunno_DATA_DIR": str(Path(directory) / "profile"),
                "HF_HOME": str(Path(directory) / "huggingface"),
                "HF_HUB_CACHE": str(Path(directory) / "huggingface/hub"),
                "HF_HUB_OFFLINE": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONUNBUFFERED": "1",
                "SUNNO_WATCH_PARENT": "1",
            })
            process = subprocess.Popen(
                [sys.executable, "-m", "server.app", "--engine", "ct2", "--model", "small",
                 "--start-stopped", "--no-speakers", "--http-port", "0", "--ws-port", "0",
                 "--recordings-path", str(Path(directory) / "recordings")],
                cwd=ROOT, env=environment, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            lines = queue.Queue()

            def read_output():
                for line in process.stdout:
                    lines.put(line)
                lines.put(None)

            reader = threading.Thread(target=read_output, daemon=True)
            reader.start()
            seen = []
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    line = lines.get(timeout=max(0.01, deadline - time.monotonic()))
                    if line is None:
                        self.fail("Desktop entry point exited before startup completed:\n" + "".join(seen))
                    seen.append(line)
                    if "not downloaded yet; waiting for a choice." in line:
                        break
                else:
                    self.fail("Desktop entry point did not reach the model-selection gate.")
                self.assertIsNone(process.poll(), "The engine did not remain available for the desktop client.")
                self.assertNotIn("Traceback", "".join(seen))
                process.stdin.close()
                process.wait(timeout=5)
                reader.join(timeout=2)
                self.assertEqual(process.returncode, 0, "Closing the desktop's stdin did not stop its engine cleanly.")
                print("PASS real desktop startup reaches the paused model-selection gate; parent EOF stops the engine")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                reader.join(timeout=2)
                process.stdout.close()


if __name__ == "__main__":
    unittest.main()
