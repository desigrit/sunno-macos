"""Run the actual desktop entry point with capture paused and no cached model."""
import os
import json
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from websockets.sync.client import connect


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
            # Reserve two distinct temporary ports without touching the installed app.
            with socket.socket() as http_socket, socket.socket() as ws_socket:
                http_socket.bind(("127.0.0.1", 0))
                ws_socket.bind(("127.0.0.1", 0))
                http_port = http_socket.getsockname()[1]
                ws_port = ws_socket.getsockname()[1]
            process = subprocess.Popen(
                [sys.executable, "-m", "server.app", "--engine", "ct2", "--model", "small",
                 "--start-stopped", "--no-speakers", "--compute-device", "cpu",
                 "--http-port", str(http_port), "--ws-port", str(ws_port),
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
                    try:
                        line = lines.get(timeout=max(0.01, deadline - time.monotonic()))
                    except queue.Empty:
                        self.fail("Desktop entry point did not start its control server:\n" + "".join(seen))
                    if line is None:
                        self.fail("Desktop entry point exited before startup completed:\n" + "".join(seen))
                    seen.append(line)
                    if "WebSocket:" in line:
                        break
                else:
                    self.fail("Desktop entry point did not start its control server.")
                # The model catalogue can benchmark a slow CI CPU. Control availability,
                # not finishing that benchmark, proves the real desktop entry point ran.
                deadline = time.monotonic() + 10
                while True:
                    try:
                        with connect(f"ws://127.0.0.1:{ws_port}", open_timeout=2, close_timeout=1) as client:
                            event = json.loads(client.recv(timeout=3))
                            self.assertIn(event.get("type"), {"status", "model_required"})
                            self.assertIsNot(event.get("wanted"), True, "Paused startup began capturing.")
                        break
                    except OSError:
                        if time.monotonic() >= deadline:
                            self.fail("The desktop control socket did not become available.")
                        time.sleep(0.05)
                self.assertIsNone(process.poll(), "The engine did not remain available for the desktop client.")
                process.stdin.close()
                process.wait(timeout=5)
                reader.join(timeout=2)
                self.assertEqual(process.returncode, 0, "Closing the desktop's stdin did not stop its engine cleanly.")
                print("PASS real paused desktop startup serves control events; parent EOF stops the engine")
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
