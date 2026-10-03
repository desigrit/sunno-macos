"""Observe real Sunno switching on a Mac without saving audio, captions or device names.

Run against an already-open app. Change inputs in Sunno or macOS, unplug/reconnect
devices, pause/resume and sleep/wake while this observes the local control socket.
This script does not send commands or change preferences.
"""
from __future__ import annotations

import argparse
import asyncio
from collections import Counter
import json
from pathlib import Path
import sys
import time

import websockets


async def observe(seconds: int, port: int) -> int:
    identity_file = Path.home() / "Library/Application Support/Sunno/engine.pid"
    identity = identity_file.read_bytes() if identity_file.is_file() else None
    deadline = time.monotonic() + seconds
    states: Counter[str] = Counter()
    captions = reconnects = switches = rollbacks = 0
    last_target = None
    wanted = running = None
    recovery_started = None
    recovery_times: list[float] = []
    connection_seen = False
    engine_changed = False
    print("Observing only. Change inputs, unplug/reconnect, pause/resume or sleep/wake in Sunno.")
    print("No audio, captions, device names or device IDs are printed or saved.")

    while time.monotonic() < deadline:
        try:
            async with websockets.connect(f"ws://127.0.0.1:{port}", open_timeout=3,
                                          close_timeout=1, max_size=2**20) as socket:
                if connection_seen:
                    reconnects += 1
                connection_seen = True
                while time.monotonic() < deadline:
                    if identity is not None:
                        current = identity_file.read_bytes() if identity_file.is_file() else None
                        engine_changed |= current != identity
                    try:
                        raw = await asyncio.wait_for(socket.recv(), timeout=min(1, deadline - time.monotonic()))
                    except asyncio.TimeoutError:
                        continue
                    event = json.loads(raw)
                    if not isinstance(event, dict):
                        continue
                    kind = event.get("type")
                    if kind in ("partial", "final"):
                        captions += 1
                    if kind not in ("status", "input"):
                        continue
                    if isinstance(event.get("wanted"), bool):
                        wanted = event["wanted"]
                    if isinstance(event.get("running"), bool):
                        running = event["running"]
                    if kind != "input":
                        continue
                    state = event.get("state")
                    # An allow-list keeps future protocol additions out of this report.
                    if state not in {"switching", "recovering", "waiting", "blocked", "ready",
                                     "selected", "paused", "failed", "rejected"}:
                        continue
                    states[state] += 1
                    if state in {"switching", "recovering", "waiting"} and recovery_started is None:
                        recovery_started = time.monotonic()
                    if state == "failed" and running:
                        rollbacks += 1
                    if event.get("committed"):
                        target = event.get("target") or {}
                        current_target = (target.get("kind"), target.get("endpoint_id"), target.get("follow_default"))
                        if last_target is not None and last_target != current_target:
                            switches += 1
                        last_target = current_target
                    if state == "ready" and running and recovery_started is not None:
                        elapsed = time.monotonic() - recovery_started
                        recovery_times.append(elapsed)
                        recovery_started = None
                        print(f"Capture ready after {elapsed:.3f}s.")
                    elif wanted is False:
                        recovery_started = None
        except (OSError, websockets.exceptions.WebSocketException, asyncio.TimeoutError):
            await asyncio.sleep(min(0.25, max(0, deadline - time.monotonic())))

    print(f"Confirmed route changes: {switches}; healthy rollbacks: {rollbacks}; socket reconnects: {reconnects}.")
    print(f"Caption events observed: {captions}, with text discarded.")
    if recovery_times:
        print(f"Capture recovery: {len(recovery_times)} observed, {min(recovery_times):.3f}s fastest, "
              f"{max(recovery_times):.3f}s slowest.")
    print("Input states: " + ", ".join(f"{name}={count}" for name, count in sorted(states.items())))
    if not connection_seen:
        print("FAIL: Sunno's local control socket was not available. Open Sunno first.")
        return 1
    if engine_changed:
        print("FAIL: the speech-engine process changed. Repeat without switching speech models or quitting Sunno.")
        return 1
    if wanted is True and running is not True:
        print("FAIL: capture had not recovered at the end. Reconnect the selected device and repeat.")
        return 1
    if switches == 0 and not recovery_times and rollbacks == 0:
        print("INCONCLUSIVE: no route change or recovery was observed.")
        return 2
    print("PASS: observed switching/recovery completed without replacing the speech engine.")
    print("Still check audible speech, app permissions and the manual checklist. This observer cannot verify them.")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=180)
    parser.add_argument("--port", type=int, default=8766)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This check observes a running macOS Sunno app.")
    if not 30 <= args.seconds <= 1800 or not 1024 <= args.port <= 65535:
        parser.error("Use 30 to 1800 seconds and a local port from 1024 to 65535.")
    try:
        raise SystemExit(asyncio.run(observe(args.seconds, args.port)))
    except KeyboardInterrupt:
        print("Observation cancelled. No app settings were changed.")
        raise SystemExit(130)
