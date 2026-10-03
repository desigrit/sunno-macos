# Audio switching and recovery

Microphones and system audio now use one replaceable, native capture process per
source. Switching input does not restart Python, WhisperKit, recognition, speaker
tracking, captions or the recorder. Audio can still have a short gap while macOS
opens a new route. No zero-gap or faster-decoding claim is made.

## Selection and recovery

- `macOS default (Input)` follows the current Core Audio default microphone.
- A named microphone pins its Core Audio device UID, not its position in a list.
  Identical display names remain separate selections. An old ambiguous name asks
  for a new selection rather than silently opening the wrong microphone.
- `System audio (this Mac)` captures this Mac's application audio through
  ScreenCaptureKit. It is not a pinned output-device loopback and is deliberately
  not labelled as a default output device.
- A candidate opens while healthy old capture continues. Preferences are saved
  after confirmation. A failed explicit switch restores the previous healthy
  source; an unavailable current source retries until it returns.
- Request IDs make replay safe. Rapid selections and late permission completions
  cannot commit an older choice. Reconnecting the control socket preserves pause
  intent and replays only the latest pending selection.
- A paused selection checks metadata without opening capture. Sleep suspends
  capture without forgetting whether the user wanted it running; wake retries
  the route without resuming a user-paused session.
- Opening has a six-second deadline. A missing capture heartbeat has a three-second
  deadline. Shutdown and hung native calls are bounded by process termination.
  Retry delays are 0.25, 0.5, 1, 2 and at most 5 seconds. Device arrivals can bypass
  the delay. Permission denial, missing dependencies and ambiguous names wait for
  an explicit retry or selection rather than spinning indefinitely.
- Core Audio route notifications are coalesced for 300 ms. Default-input metadata
  is also checked every two seconds as a fallback. Failed metadata queries retain
  a healthy route, rather than masquerading as a changed default.
- Native conversion is rebuilt when the source format changes. System-audio
  silence is emitted only while ScreenCaptureKit supplies callbacks or acknowledges
  a health check. Stream errors trigger recovery instead of being hidden by silence.

## Automated checks on macOS

The GitHub workflow compiles the complete SwiftUI app and the release capture
service for Apple Silicon. It tests native Core Audio metadata, metadata-only
paused selection, and real AVAudioConverter transitions between 48 kHz, 44.1 kHz
and 96 kHz stereo sources. Synthetic samples stay in memory.

The same run exercises supervisor failure, hangs, bounded retry, rollback,
overlapping requests, control reconnection, pause and recording continuity through
the real Python WebSocket handler. Real Swift checks cover input intent, preference
migration, sleep/wake intent, model and recording state, and transcript ordering.
Protocol, browser-recovery, palette and recording checks run too.

```bash
swift build -c release --package-path capture-service
./.venv/bin/python tests/test_native_capture_service.py
./.venv/bin/python tests/test_capture_recovery.py
./.venv/bin/python tests/test_input_switch.py
```

Hosted CI is not a microphone or Bluetooth hardware test. The complete signed
bundle's permissions, USB/Bluetooth disconnects, static-desktop system audio,
real speech, recording playback and physical sleep/wake still require a Mac.

## Real-Mac evaluation

Build and sign with a stable identity using `scripts/package-app.sh`, launch the
resulting app, grant its microphone and screen/system-audio permissions, and wait
for the speech model to be ready. Do not switch models during these checks.

This optional observer reads the already-running app's local control socket. It
sends no commands, changes no preferences, and saves no audio, captions or device
names. It reports route changes, recovery times and whether the speech engine was
replaced. It returns an inconclusive result if nothing was switched.

```bash
./.venv/bin/python scripts/check-audio-switching.py --seconds 300
```

While observing, test the following in Sunno and macOS:

| Check | Expected result |
| --- | --- |
| Follow default, then change macOS default input | Captions move to the new input without restarting the speech engine. |
| Pin a microphone, then change macOS default | The pinned microphone remains selected. |
| Quickly select A, B and A, including duplicate names | The last selection wins; its confirmed UID survives relaunch. |
| Unplug USB or disconnect Bluetooth, then reconnect | Existing captions stay visible; capture reconnects when the same device returns. |
| Pause during a failed switch or retry, then change devices | The app stays paused and does not open capture until Resume. |
| Switch microphone and system audio during a disposable recording | One recording remains open; playback and transcript contain the captured segments. |
| Leave system audio silent on a static desktop for ten minutes | No false stall loop; captions resume when app audio starts. |
| Change Bluetooth profiles, output route and sample rate | Conversion recovers without stuck silence, crashes or distorted captions. |
| Sleep/wake while running, then repeat while paused | Running intent recovers; paused intent stays paused. |
| Deny and re-enable permissions | A clear permission message appears; Resume retries after access is granted. |
| Quit or terminate Sunno while capture is active | No capture helper keeps the microphone open; relaunch can bind both local ports. |

Observe the app's meter and captions as well as the report. A healthy heartbeat
alone does not prove that the intended microphone or spoken words reached the
recogniser. Recovery timing includes device/framework availability and is not an
inference-speed benchmark.

`server/pcm_socket.py` and `--pcm-port` remain for old command-line integrations.
The shipped app no longer uses the old in-app ScreenCaptureKit socket writer.
