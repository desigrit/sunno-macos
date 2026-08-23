"""System audio on macOS, handed over a socket by the native client.

There is no WASAPI loopback here. `loopback.py` is Windows in full and `pyaudiowpatch` publishes
no macOS wheel and no sdist, so none of it crosses. macOS keeps system audio behind
ScreenCaptureKit or, from 14.4, a Core Audio process tap, and both are Objective-C or Swift APIs
that belong in the app rather than in this process.

So the split is: the Swift side captures, downmixes and resamples, and writes exactly what
`MicrophoneStream` yields — mono float32 at 16 kHz — down a loopback socket. This is the third
implementation of that same promise, and everything above it is indifferent to which one is in
use, which is the seam `loopback.py` already argued for.

The idle-versus-dead distinction is carried over deliberately, because it is the one lesson this
path has already cost. `docs/CONTEXT.md` records the stall warning being exempted for loopback to
kill a false alarm, which removed the true alarm with it, and a Phonak headset leaving Bluetooth
range then left the app showing a running clock above a transcript that could never gain another
line. Here the socket is the liveness signal: still connected means the capture is alive and any
gap is a quiet desktop, so real silence is yielded and level reporting stays alive. Closed means
capture has genuinely stopped, and the loop ends so the UI can say so.
"""

from __future__ import annotations

import queue
import socket
import threading
import time
from typing import Callable, Iterator

import numpy as np

from .config import FRAME_SAMPLES, SAMPLE_RATE

# Matches loopback.py: short enough that the silence generator tracks the wall clock closely,
# long enough not to spin a core.
_IDLE_POLL_S = 0.1
_FRAME_SECONDS = FRAME_SAMPLES / SAMPLE_RATE
_MAX_CATCHUP_FRAMES = 16
_SILENCE = np.zeros(FRAME_SAMPLES, dtype=np.float32)

_CONNECT_TIMEOUT_S = 10.0


class PCMSocketOpenError(RuntimeError):
    """The client never offered audio. Carries a sentence a person can act on."""


class PCMSocketStream:
    """Yields mono float32 frames of exactly FRAME_SAMPLES at SAMPLE_RATE.

    Mirrors MicrophoneStream's contract so the pipeline is indifferent to which one it is given.
    No resampling or downmixing happens here: the client has already done both, because it is
    the side that knows what format the capture API handed it.
    """

    def __init__(self, port: int, host: str = "127.0.0.1", max_queued_blocks: int = 128):
        self.port = int(port)
        self.host = host
        self._queue: queue.Queue[np.ndarray | None] = queue.Queue(maxsize=max_queued_blocks)
        self._socket: socket.socket | None = None
        self._reader: threading.Thread | None = None
        self._closing = threading.Event()
        self._connected = threading.Event()
        self.dropped_blocks = 0
        self.capture_rate: int = SAMPLE_RATE
        self.capture_channels: int = 1

    def __enter__(self) -> "PCMSocketStream":
        try:
            sock = socket.create_connection((self.host, self.port), timeout=_CONNECT_TIMEOUT_S)
        except OSError as exc:
            raise PCMSocketOpenError(
                "Sunno could not reach the system audio capture. "
                "Try choosing the input again."
            ) from exc

        # Nagle would coalesce 32 ms of speech into larger, later packets, which is latency
        # bought for bandwidth that a loopback socket does not need.
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(_IDLE_POLL_S)
        self._socket = sock
        self._connected.set()

        self._reader = threading.Thread(target=self._read_loop, name="pcm-socket", daemon=True)
        self._reader.start()
        return self

    def __exit__(self, *exc) -> None:
        self._closing.set()
        self._connected.clear()
        if self._socket is not None:
            try:
                self._socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self._socket.close()
            except OSError:
                pass
            self._socket = None
        self._wake()

    @property
    def device_name(self) -> str:
        return "System audio"

    @property
    def is_alive(self) -> bool:
        """Whether the client is still sending.

        The socket is the liveness signal. A quiet desktop and a dead capture look identical in
        the data — both are an empty queue — and only the connection tells them apart.
        """
        return self._connected.is_set() and not self._closing.is_set()

    def _read_loop(self) -> None:
        # float32, so four bytes a sample. Read in whole samples and keep any remainder for the
        # next pass: TCP is a byte stream and will happily split a sample down the middle.
        remainder = b""
        try:
            while not self._closing.is_set():
                sock = self._socket
                if sock is None:
                    break
                try:
                    chunk = sock.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not chunk:
                    break

                data = remainder + chunk
                usable = len(data) - (len(data) % 4)
                remainder = data[usable:]
                if usable == 0:
                    continue

                block = np.frombuffer(data[:usable], dtype="<f4").astype(np.float32, copy=False)
                try:
                    self._queue.put_nowait(block)
                except queue.Full:
                    # Drop rather than block. Falling behind on the reader thread would push
                    # back on the client and eventually on the capture callback, and a late
                    # caption is better than a stalled one.
                    self.dropped_blocks += 1
        finally:
            self._connected.clear()
            self._wake()

    def _wake(self) -> None:
        """Nudge a waiting consumer, without ever blocking on a full queue.

        Both shutdown paths run on threads that nothing is draining, so a blocking put here
        deadlocks whenever the queue happens to be full: the reader parks waiting for a slot
        and __exit__ parks waiting for the same slot, and the capture pump never returns. The
        queue fills routinely, because a Whisper decode is hundreds of milliseconds during
        which nobody calls get(), so pausing mid-decode was enough to wedge it.

        Dropping the sentinel is safe. It is only an early wakeup: frames() already leaves the
        loop on `is_alive` going false, which the socket closing guarantees.
        """
        try:
            self._queue.put_nowait(None)
        except queue.Full:
            pass

    def frames(self, should_continue: Callable[[], bool] | None = None) -> Iterator[np.ndarray]:
        keep_going = should_continue or (lambda: True)
        pending = np.empty(0, dtype=np.float32)
        last_yield = time.monotonic()

        while keep_going():
            try:
                block = self._queue.get(timeout=_IDLE_POLL_S)
            except queue.Empty:
                # Nothing playing. ScreenCaptureKit does not promise a callback while the
                # machine is silent, so yield real silence rather than spinning: silence is the
                # truthful description of an idle output, and it keeps level reporting alive so
                # the UI can tell "nothing is playing" apart from "capture has died".
                if not self.is_alive:
                    break

                # Enough frames to cover the wall-clock gap, not one per poll. The pipeline
                # measures silence by counting frames, so under-producing would stretch
                # end-of-utterance detection by the same factor.
                now = time.monotonic()
                owed = int((now - last_yield) / _FRAME_SECONDS)
                if owed <= 0:
                    continue
                # Cap the catch-up so a scheduling hiccup cannot dump a burst of silence into
                # the VAD in one go.
                for _ in range(min(owed, _MAX_CATCHUP_FRAMES)):
                    yield _SILENCE
                last_yield = now
                continue

            if block is None:
                break
            if block.size == 0:
                continue

            pending = np.concatenate((pending, block))
            while pending.size >= FRAME_SAMPLES:
                yield pending[:FRAME_SAMPLES]
                pending = pending[FRAME_SAMPLES:]
                # Real audio resets the clock too, so the silence generator only ever fills
                # gaps rather than double-counting time already covered by captured frames.
                last_yield = time.monotonic()
