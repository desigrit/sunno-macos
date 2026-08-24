# Sunno for macOS: state of the work

**A handover document.** It exists so somebody — or some agent — arriving with no memory of the
conversation that produced this port can pick it up without guessing. It records what the product
is, what has been built, what every measurement said, which decisions were reversed and why, what
is deliberately unfinished, and what to do next.

It is deliberately long. The alternative is a fresh pair of hands re-deriving conclusions that
already cost a day of measurement, or worse, re-introducing a bug that has already been fixed
once. Where a section states a number, that number was measured on the machine described in
[Environment](#16-environment-what-this-was-built-on) unless it says otherwise.

Last updated at commit `87dacd3`.

---

## Table of contents

1. [How to read this](#1-how-to-read-this)
2. [What Sunno is, and who it is for](#2-what-sunno-is-and-who-it-is-for)
3. [The promises, which are the real constraints](#3-the-promises-which-are-the-real-constraints)
4. [The two repositories](#4-the-two-repositories)
5. [Current state at a glance](#5-current-state-at-a-glance)
6. [Getting it running](#6-getting-it-running)
7. [Architecture](#7-architecture)
8. [The wire protocol](#8-the-wire-protocol)
9. [The engine story](#9-the-engine-story)
10. [Every measurement taken](#10-every-measurement-taken)
11. [Decisions, including the ones that were reversed](#11-decisions-including-the-ones-that-were-reversed)
12. [Bugs found, and the lesson from each](#12-bugs-found-and-the-lesson-from-each)
13. [What is parked, and what it costs](#13-what-is-parked-and-what-it-costs)
14. [What to do next](#14-what-to-do-next)
15. [Landmines](#15-landmines)
16. [Environment: what this was built on](#16-environment-what-this-was-built-on)
17. [How to verify you have not broken anything](#17-how-to-verify-you-have-not-broken-anything)
18. [File index](#18-file-index)

---

## 1. How to read this

If you are picking this up cold, read in this order:

1. This document, sections 2 through 7. That gives you the product, the promises and the shape.
2. `docs/MACOS-PORT.md`, which is the decision record: rejected alternatives, evidence, and what
   is still unverified. It is the *why* behind most of what section 7 describes.
3. `README.md`, which is written for somebody using the app rather than building it. Read it to
   see what has been promised to users in public.
4. `docs/macos-mockup.html`, the approved interface. Open it in a browser before reading any
   Swift; it is faster than reading views.
5. `docs/CONTEXT.md` in [desigrit/sunno](https://github.com/desigrit/sunno), which carries
   everything learned building the Windows app: the promises, the measurements, the decisions
   that were made twice, the bugs worth knowing about. It stays in that repository because most
   of what it records is about the pipeline, which both platforms share. **It is the single most
   useful document in either repository and it is not in this one.**

Two conventions used throughout the codebase, worth knowing before you read any of it:

- **Comments explain why, not what.** If a line looks odd, there is usually a comment above it
  saying which failure it prevents. Several of them name a specific bug that cost hours. Do not
  delete them to tidy up; they are the reason the same bug has not come back.
- **Measurements are quoted where they are used.** A constant with a number beside it in a
  comment came from a measurement, not a preference. Changing it without re-measuring is how the
  Windows build acquired two of its recorded reversals.

---

## 2. What Sunno is, and who it is for

Sunno is an offline live-captioning app. You point it at a microphone, or at the audio your Mac
is playing, and it writes down what is being said as it is said. It labels who is speaking, so a
four-way conversation reads like a conversation rather than one long paragraph.

It exists because its author misses words. Not the big ones — the small ones: the end of a
sentence when somebody turns their head, the name of a restaurant, the punchline everybody else
laughs at. That framing matters more than it sounds, because it decides trade-offs. This is not a
transcription product for meetings that get filed. It is a reading aid for a conversation
happening in front of you, and **latency is a correctness property, not a performance metric**. A
caption that arrives four seconds late has failed even if every word is right.

"Sunno" means "listen" in Hindi and Urdu.

### Who uses it

One person, daily, on Windows, plus whoever else finds it. That user:

- Is hard of hearing and wears a Phonak hearing aid.
- Routes system audio and the hearing aid through the app every day, which makes system audio the
  feature that decides whether the port is usable rather than merely working.
- Speaks and listens to accented English, which is why the model choice is Whisper rather than
  something faster. `ENGINEERING.md` in the Windows repository has the numbers: 7.2% WER on
  SVARAH against 20.7% for a commercial `en-IN` model.

### What that implies for engineering

Three things follow from the above and are easy to forget:

1. **An optimistic number is worse than no number.** The clarity score, the model picker's delay
   estimates, and the "No audio" warning all exist to tell the user something true about whether
   they are being heard. Each of them has been wrong at some point in this project's history and
   each time the failure was silent.
2. **Accessibility settings are not garnish.** Reduce Motion is honoured. Differentiate Without
   Color is honoured by construction — uncertain words are grey *and* italic *and* underlined,
   never colour alone.
3. **Device names are health information.** A capture device called
   "Headset (R-Phonak hearing aid)" tells a reader that the user wears a hearing aid. Device names
   never reach a log or the diagnostics export. This is enforced, not aspirational, and there is a
   comment saying so at every point where it could leak.

---

## 3. The promises, which are the real constraints

From the Windows `README.md` and `PRIVACY.md`, and inherited wholesale:

| Promise | What it forbids |
|---|---|
| Everything runs on this machine | No cloud inference, no telemetry, no account |
| Works with the Wi-Fi off | Nothing may require the network after the model download |
| Exactly one network operation in the app | The model download, and nothing else |
| Audio is never written to disk | No caching of raw audio, ever |
| Device names never leave the machine | Not in logs, not in the diagnostics export |

The diagnostics export deserves a note because it is the one feature whose *purpose* is to send a
file to a stranger. It is built as an **allow-list, not a filter**. A filter has to anticipate
every category of secret; an allow-list only ever emits what somebody deliberately put on it. If
you add a field to that report, you are making a privacy decision.

**A port that keeps the captions and breaks any of the above has not shipped Sunno. It has
shipped something that resembles it.**

---

## 4. The two repositories

| Repository | Contains |
|---|---|
| [`desigrit/sunno`](https://github.com/desigrit/sunno) | The Windows app (WinUI 3), the original Python engine, `docs/CONTEXT.md` and `docs/ENGINEERING.md` |
| [`desigrit/sunno-macos`](https://github.com/desigrit/sunno-macos) | This one: the macOS app, and its own copy of the Python engine |

### They are independent, and that is recent

The engine used to be carried here as a pinned git submodule at `external/sunno`. It is now
**vendored** at `server/`. This repository clones, builds and runs with no second checkout and no
`--recurse-submodules`.

The reasoning, at length, is in `docs/MACOS-PORT.md` under "Reversal: the backend as a submodule".
The short version: the submodule was defensible while the only thing crossing the boundary was
reading source text at test time. It stopped being defensible the moment a feature needed the
engine changed. Adding system audio meant a commit in the other repository, a pin bump here, and a
client branch nobody could clone until the engine branch landed. Two projects that cannot be built
independently are one project with extra steps.

**The cost is accepted, not hidden.** `server/` exists in both repositories, and an improvement
that belongs to both is pushed to both. Some of what is vendored is inert here — `loopback.py` is
WASAPI, `cuda_setup.py` is NVIDIA — and both are kept unchanged so the two copies stay easy to
diff.

There is one live branch in the other repository from this work:

- `desigrit/sunno` branch **`macos-system-audio`** (commit `b2e0414`), unmerged. It carries
  `server/pcm_socket.py`, the `--pcm-port` argument, and the three path fixes described in section
  12. It is no longer needed by this app, because the engine is vendored, but the path fixes are a
  genuine improvement to the shared engine. **It is somebody's decision whether to merge it.**

---

## 5. Current state at a glance

### What works

- **The app builds and runs.** It was written on Windows and had never been compiled; it now
  compiles clean with no warnings and runs.
- **Live captions from the microphone**, with provisional text replaced by final text at the
  utterance boundary.
- **Live captions from system audio** — YouTube, a video call, anything the Mac is playing —
  through ScreenCaptureKit.
- **Whisper decodes on the Neural Engine and GPU** through WhisperKit and Core ML, three to five
  times faster than the processor-only path it replaced.
- **Speaker labelling**, model picker, compact mode, settings, conversation timer, the "No audio"
  stall warning, diagnostics export.
- **Both contract tests pass**, and the protocol one now checks against the engine that actually
  runs rather than a pinned commit.
- **A fresh clone works**: clone, `./scripts/setup-engine.sh`, build, run. Verified end to end.

### What does not work, or is deliberately off

| Thing | State | Section |
|---|---|---|
| Clarity score | Hidden on the WhisperKit engine. The badge does not appear | [13.1](#131-the-clarity-score) |
| Model picker delay estimates | Wrong, in both directions. Known and accepted for now | [13.2](#132-the-model-picker-lies) |
| `add_context` | Accepted and ignored on the WhisperKit engine | [13.3](#133-add_context-is-ignored) |
| App Sandbox | Off. Deferred until distribution is decided | [13.5](#135-distribution) |
| Screen recording permission | Must be granted by hand; macOS never prompts | [15](#15-landmines) |
| Speaker embedding model | Not present, so speaker labelling is off in this checkout | [13.4](#134-speaker-labelling-is-off-in-this-checkout) |

### Commit history of this work

```
17d9916  The macOS client, moved out of the backend repository   (pre-existing)
309006a  The first build, the bugs it found, and system audio
0f79c92  Guard the capture continuation against a double resume
8a4ead3  Stand on its own: vendor the engine, and a picker worth using
5af6d55  Merge: the macOS port stands on its own
eaa02bc  Bring back the radio list, and make the whole band the target
783ff8d  Match the Windows model picker, down to the size format
f7dc6de  Stage A: a WhisperKit decode service, and what it measured
b2e1cfd  Wire WhisperKit in: Whisper now decodes on the Neural Engine
08fbc42  Fix the hang on "Loading the model", and stop writing to Documents
87dacd3  Bring the README up to date with the engine that actually runs
```

Every commit message is long and explains its reasoning. They are worth reading in order if you
want the narrative rather than the summary.

---

## 6. Getting it running

### From a fresh clone

```bash
git clone https://github.com/desigrit/sunno-macos.git
cd sunno-macos
./scripts/setup-engine.sh
```

`setup-engine.sh` creates `.venv`, installs `requirements-macos.txt`, builds the WhisperKit
service, and then tells you which engine you got:

```
    speech engine: whisperkit (neural engine)
```

If it says `ct2 (processor only)`, the Swift service did not build and Whisper will run three to
five times slower. Run `cd whisperkit-service && swift build -c release` to see why.

### Building the app

The documented path is XcodeGen, which needs Xcode:

```bash
brew install xcodegen && xcodegen generate && open Sunno.xcodeproj
```

`project.yml` is the source of truth and the `.xcodeproj` is generated rather than committed: a
pbxproj conflicts on every branch and nobody reviews it, where forty lines of YAML can be read in
a pull request.

**There is also a Command Line Tools path**, which is how all of this work was done, because the
machine had no Xcode. It is not committed to the repository; see
[section 16](#16-environment-what-this-was-built-on) for what it does and why you might want it.

### Running the engine on its own

Useful for testing without the app:

```bash
./.venv/bin/python -m server.app --list-devices
./.venv/bin/python -m server.app --model small
./.venv/bin/python -m server.app --model small --engine ct2     # force the processor path
```

The engine serves an HTTP endpoint on 8765 and a WebSocket on 8766. Both are hardcoded defaults
and both are overridable with `--http-port` and `--ws-port`.

### Watching what the engine is doing

The app captures the engine's stdout and discards it, deliberately: the engine prints latency and
speaker ids but never transcript text, and inheriting would put it in the system log where nobody
chose to keep it. So when you need to see it, run the engine yourself rather than through the app.

To watch the wire without the app:

```bash
./.venv/bin/python - <<'PY'
import asyncio, json, websockets
async def main():
    async with websockets.connect("ws://127.0.0.1:8766") as ws:
        while True:
            d = json.loads(await ws.recv())
            if d.get("type") in ("partial", "final", "status"):
                print(d.get("type"), d.get("text") or d.get("state"))
asyncio.run(main())
PY
```

That is the single most useful debugging tool in this project. Several bugs described in section
12 were found with it, and one of them — captions rendering at zero height — was *only* findable
with it, because the events were arriving perfectly while the window looked empty.

---

## 7. Architecture

### 7.1 The shape

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │  Sunno.app  (SwiftUI + AppKit)                                       │
  │                                                                      │
  │   SunnoApp ── MainView ── Sidebar / Transcript / CommandBar          │
  │      │                                                               │
  │      ├── CaptionClient  ──── WebSocket 8766 ────┐                    │
  │      ├── DeviceCatalog  ──── HTTP 8765 ─────────┤                    │
  │      ├── BackendHost    ──── spawns ────────────┼──┐                 │
  │      └── SystemAudioCapture (ScreenCaptureKit)  │  │                 │
  │               │                                 │  │                 │
  │               └── PCM over a loopback socket ───┼──┼──┐              │
  └─────────────────────────────────────────────────┼──┼──┼──────────────┘
                                                    │  │  │
  ┌─────────────────────────────────────────────────▼──▼──▼──────────────┐
  │  python -m server.app   (the pipeline)                               │
  │                                                                      │
  │   capture ─► preprocess ─► Silero VAD ─► endpointing ─► two passes   │
  │                                              │                       │
  │                                              ├── speaker embedding   │
  │                                              └── SpeechEngine ───┐   │
  └──────────────────────────────────────────────────────────────────┼───┘
                                                                     │
  ┌──────────────────────────────────────────────────────────────────▼───┐
  │  whisperkit-service   (Swift, over a pipe)                           │
  │     WhisperKit ─► Core ML ─► Neural Engine and GPU                   │
  └──────────────────────────────────────────────────────────────────────┘
```

Three processes. The app owns the window and the macOS-native work; the Python process owns the
pipeline; the Swift service owns the decode. They are separate processes on purpose: a crash in
inference leaves the window alive and reconnecting instead of taking the app down
mid-conversation.

### 7.2 The Swift app

Everything under `Sunno/`. Built as an app bundle, deployment target macOS 13.3.

#### `SunnoApp.swift` — entry point and wiring

Owns every long-lived object as a `@StateObject`: settings, transcript store, caption client,
device catalogue, window chrome, backend host, system audio capture. Holds the menu bar commands
and the diagnostics allow-list.

`startUp()` is the whole of the launch sequence and it is **claimed exactly once per launch**
through `backend.claimStartUp()`. This matters: it is driven by `onAppear`, which fires again
whenever SwiftUI rebuilds the hierarchy, and `startUp()` replaces the engine. Running it twice
tore down a model that was still loading and started another, so the window never reached
"listening" and no caption ever arrived. See [12.6](#126-startup-ran-on-every-onappear).

The launch sequence branches on whether the remembered device is system audio:

- **Microphone or a loopback endpoint**: start the engine with the saved device, connect the
  socket, refresh the device list, then reconcile the saved device by name.
- **System audio**: start the *capture* first so the engine can be given its port on the first
  try, then start the engine. Bringing it up on the microphone and swapping afterwards costs a
  model load that is thrown away, which is half a minute of empty window for nothing.

If system audio fails, `startOnMicrophone()` runs. **An accessibility tool that captions nothing
because one capture path was refused has failed at the only thing it is for.**

#### `Services/BackendHost.swift` — owning the Python process

Spawns `python -m server.app`, finds `server/app.py` by walking up from the app bundle, and
prefers `.venv/bin/python` over anything on `PATH`.

Most of this file is about **not orphaning the child**. A child process outlives its parent on
Unix unless something intervenes, and an orphaned engine holds the microphone and both ports. The
next launch then fails to bind and quietly attaches to the stale process, which presents as a
working app showing state that stopped updating. Three exits need three mechanisms:

| Exit | Mechanism |
|---|---|
| Quit, Cmd-Q, window closing | `NSApplication.willTerminateNotification` |
| `kill`, SIGTERM, SIGINT | A dispatch signal source — the default action dies before any notification runs |
| SIGKILL, crash | A pid file on disk, reaped on the next launch |

The third is the only one that survives a crash, and it is why a pid file exists at all.

**Identity is pid plus start time, never the executable path.** A framework CPython re-execs
itself into `Python.app/Contents/MacOS/Python` moments after launch, so the path is not stable for
the life of its own process. Using it made the reap silently never fire. `exec` preserves both pid
and start time, which is what makes them a sound identity.

`stop()` waits, bounded, for the child to actually exit before returning, because the replacement
binds the same two ports and SIGTERM is not instant.

The `terminationHandler` guards on **process identity**, not on a flag. It runs on a background
queue, so a deliberately replaced engine used to report its own SIGTERM over its healthy
successor. See [12.5](#125-the-false-engine-stopped-banner).

#### `Services/CaptionClient.swift` — the socket

A WebSocket client with an **indefinite** reconnect ladder, backing off to a two-second ceiling
and staying there. The engine restarting underneath it is a normal Tuesday: changing the device or
the model tears it down and brings it back. A client that gave up after a few attempts would leave
somebody looking at a frozen transcript with no way back except quitting.

Decoding never throws upward. An event this build does not understand is counted and dropped,
because the alternative is a newer engine silently stopping the captions of somebody
mid-conversation. `BackendEvent.Kind.unknown` is the mechanism and `undecodableEvents` is the
counter, surfaced in diagnostics so "it just does not do that any more" has an explanation.

#### `Services/SystemAudioCapture.swift` — ScreenCaptureKit

Runs an `SCStream` with `capturesAudio`, converts 48 kHz stereo to 16 kHz mono through
`AVAudioConverter`, and serves raw float32 PCM on a **loopback-only** TCP port.

Three things in here are load-bearing:

1. **The conversion uses `AVAudioConverter`, not decimation.** 48000/16000 is exactly 3, so taking
   every third sample is tempting and wrong: without a low-pass first it folds everything above
   8 kHz back into the speech band as aliasing, which a speech model hears as noise it will
   happily transcribe words out of.
2. **The listener binds `127.0.0.1` explicitly.** `NWListener(using: .tcp, on: .any)` reads as
   "any port" and is also any *address*. See [12.8](#128-the-capture-socket-was-open-to-the-network).
3. **Permission is checked with `CGPreflightScreenCaptureAccess`.** ScreenCaptureKit does not
   throw when permission is missing — `SCShareableContent` succeeds and reports *no displays*, so
   the natural reading of a failure is "this Mac has no screen", which is never true.

A 2×2 screen output at one frame every two seconds is added and immediately discarded. Whether an
audio-only `SCStream` is legal was listed as unverified in the port doc; taking a screen output
and dropping every frame sidesteps the question at no measurable cost.

#### `Services/DeviceCatalog.swift` — what can be captured

Fetches `/devices.json` from the engine rather than enumerating natively, so the index the user
picks and the index the engine opens cannot disagree.

Adds one synthetic entry the engine cannot know about: **System audio (this Mac)**. On macOS the
engine enumerates no loopback endpoints — `loopback.py` is WASAPI — so without this the picker's
"System audio" section is a heading with nothing under it on every Mac.

`resolve(index:name:isLoopback:)` re-finds a remembered device **by name first, index second**.
Indices are positional: plugging in an interface renumbers everything after it, and trusting the
index would silently caption a different device. On this app that can mean captioning a room
instead of a hearing aid.

#### `Services/AppSettings.swift` — preferences

`UserDefaults`, not a hand-rolled file: macOS has one, it is backed up and migrated by the system,
and a hand-rolled file would be a worse version of it.

Persists the caption size, clarity toggle, force-CPU, always-on-top, compact mode, the selected
model, the capture device (index, name and whether it is a loopback source), whether setup has
been completed, whether the screen-capture explanation has been shown, and **two window
geometries**. Compact and expanded are remembered separately because they are used in different
places on the screen and at very different sizes; sharing a frame drags each into the other's
shape at every switch.

#### `Models/TranscriptStore.swift` — everything on screen

Assembles lines, speakers, status and problems from the event stream.

**The ordering rule that matters**: `speaker_merged` and `speaker_deleted` are handled *before*
the roster that follows them. The engine guarantees that ordering deliberately. Handle them the
other way round and captions keep the name of somebody the user just asked the app to forget.

Holds two sub-objects rather than publishing their values itself:

- `meter: AudioMeter` — the input level and whether speech is present.
- `clock: SessionClock` — the conversation timer and the stall warning.

That split is not tidiness. `pipeline.py` publishes a level roughly **ten times a second** for as
long as capture runs. While those values lived on the store, every one of those events invalidated
every view observing it: the settings window redrew ten times a second, which reads as a flicker
across its tab bar, and so did the transcript, the sidebar and the model picker. SwiftUI
invalidates per observable object, so putting the only fast-moving values in their own type means
a level event redraws the meter and nothing else.

#### `Models/SessionClock.swift` — the timer and the stall warning

Ported from `MainWindow.xaml.cs:704-830` including the reasoning.

- **The count accumulates across pauses.** Only clearing the transcript resets it. Ducking out for
  a private aside is what the pause button is for, and zeroing a forty-minute reading because
  somebody stepped away for thirty seconds punishes exactly the behaviour the control exists to
  encourage.
- **"No audio" after four seconds without a level event.** A counter that keeps climbing is read
  as "everything is fine", so it must not keep climbing once audio has stopped arriving. The
  capture thread can die while the process lives.
- The timer runs in `.common` run loop modes, so it keeps counting while a menu is open or the
  window is being dragged. A clock that freezes whenever the device picker is open would look like
  the stall it exists to report.

`CONTEXT.md` records this warning being got wrong in *both* directions: first exempted for loopback
to silence a false alarm, which removed the true alarm with it, and then a Phonak headset dropping
off Bluetooth mid-session left the app showing a running clock above a transcript that could never
gain another line.

#### `Views/` — the interface

| File | What it is |
|---|---|
| `MainView.swift` | Window body, compact body, the problem banner, the empty state, the toolbar |
| `SidebarView.swift` | Speakers, and the model picker beneath them |
| `TranscriptView.swift` | The caption list, pinned to the bottom |
| `CaptionTextView.swift` | AppKit text, for per-word confidence on hover |
| `CommandBar.swift` | Level meter, device picker, transport, status line |
| `SettingsWindow.swift` | Cmd-comma, tabbed |
| `FirstRunView.swift` | The model picker on first run |
| `SpeakerEditor.swift` | Rename, mark as self, merge |

**`CaptionTextView` is AppKit, and that is deliberate.** Hovering a word to see how confident the
model was needs hit-testing that SwiftUI's `Text` cannot do; `NSTextView` exposes
`characterIndexForInsertion(at:)`. The styling alone would work in SwiftUI; the hover would not.

It also has to **report its own height**, through `sizeThatFits` and an `intrinsicContentSize`
override measured from the layout manager. An `NSTextView` has no useful intrinsic height outside
the `NSScrollView` it is built to live in. Without it every caption row laid out at zero and the
transcript looked blank while events arrived perfectly. See
[12.4](#124-captions-rendered-at-zero-height).

**The model picker is a disclosure holding radio rows**, and its header is a `Button` rather than
a `DisclosureGroup` label. A disclosure on macOS wires only its chevron to the binding and its
label is inert however it is shaped, so the section could otherwise be opened only by hitting a
triangle a few points across. Owning the header means the whole sixty-four point band responds.
The reveal animates a clipped height rather than inserting rows, so the contents do not appear all
at once while the header is still moving.

The row layout mirrors `ModelRow.cs` exactly: name and description on the left, and — only when
the model is not on disk — its download size and a download glyph on the right. Keeping size out
of the description line leaves the description readable and makes a missing model recognisable
without reading anything. The size format matches `ModelRow.FormatSize`, which divides by **1024**
and trims the decimal, so `large-v3` reads "3 GB" on both platforms rather than "3.1 GB" here.

#### `Windowing/WindowChrome.swift` — the window itself

All AppKit, because SwiftUI has no vocabulary for it. A `WindowGroup` cannot float above other
applications, cannot swap its minimum size, and cannot keep two separate saved frames. Compact
mode needs all three.

**The rule that is easy to get backwards**: the minimum size must be lowered *before* shrinking
into compact and raised only *after* expanding out of it. In the other order the window silently
refuses the resize, because it is still holding a minimum larger than the size being requested.

Compact is **refused** while the setup screen or a dead engine owns the window, because compact
would hide the thing that has to be dealt with first. Being forced out that way is not the user
changing their mind, so `settings.isCompact` is left alone and the window simply shows expanded
until the obstruction clears.

### 7.3 The Python engine

Everything under `server/`. A vendored copy of the Windows engine, with four files changed.

#### The pipeline

`pipeline.py` is the heart and **nothing in this port has changed it**. It carries:

- The endpointing state machine: start debounce, pre-roll, end silence at 520 ms, forced commit on
  long monologues.
- The two-pass worker discipline: a single-slot partial queue so a newer snapshot supersedes a
  stale one, finals take priority and cancel their own partial. This is what keeps captions close
  to live and it is not obvious.
- Level publishing at roughly 10 Hz.
- Speaker embedding and online matching through `speaker.py`.

`config.py` holds every tunable with the reason beside it. The ones that come up most:

| Constant | Value | What it does |
|---|---|---|
| `SAMPLE_RATE` | 16000 | Everything downstream assumes it |
| `FRAME_SAMPLES` | 512 | Silero VAD v6 works on 512-sample frames, 32 ms |
| `partial_beam_size` | 1 | Greedy, for speed |
| `final_beam_size` | 5 | Beam search, for accuracy |
| `end_silence_ms` | 520 | How long silence must last to end an utterance |
| `partial_interval_ms` | 450 | How often a provisional decode runs |
| `no_speech_threshold` | 0.6 | Hallucination suppression |
| `log_prob_threshold` | -1.0 | Hallucination suppression |
| `compression_ratio_threshold` | 2.4 | Hallucination suppression |
| `drop_no_speech_above` | 0.6 | A second guard, because faster-whisper's own only fires when the log-prob check also fails |
| `low_confidence_below` | 0.55 | Words below this are shaded as uncertain |

#### The engine abstraction

`engine.py` defines a three-method Protocol, and it is the reason the WhisperKit change was small:

```python
class SpeechEngine(Protocol):
    settings: Settings
    def partial(self, audio) -> Transcript: ...
    def final(self, audio) -> Transcript: ...
    def warmup(self) -> float: ...
```

`Transcript` carries `text`, `duration_s`, `latency_ms`, `is_final`, an **optional** `clarity`, and
a list of `Word(text, probability)`. Clarity being optional is what lets an engine that cannot
report confidence behave correctly rather than inventing a number.

There are four implementations:

| Kind | File | Runs on |
|---|---|---|
| `whisperkit` | `asr_whisperkit.py` | Core ML: Neural Engine and GPU. **Default on macOS** |
| `ct2` | `asr.py` | CTranslate2, processor only. The fallback |
| `stream` | `asr_stream.py` | sherpa-onnx transducers, for the lean tier |
| `onnx` | `asr_onnx.py` | onnxruntime-genai, for Windows on ARM. Never used here |

`resolve_engine(preference, model_id)` picks. A streaming model id forces the streaming engine —
a transducer and a Whisper checkpoint are different artifacts, not two settings of one thing.
Otherwise WhisperKit wins when its service is built, then CTranslate2. `--engine` overrides.

#### `asr_whisperkit.py` — the new one

Spawns `whisperkit-service` and talks to it over a pipe. Also carries three module-level functions
used before an engine exists: `is_available()`, `model_is_available(model_id)` and
`download_model(model_id, on_progress)`.

`weights_root()` returns `data_dir() / "whisperkit"`. **Not** WhisperKit's default, which is
`~/Documents/huggingface`: several gigabytes of model weights do not belong in the folder somebody
keeps their own files in, with nothing there to say what put them there.

#### `pcm_socket.py` — system audio into the pipeline

A third implementation of the same stream contract `MicrophoneStream` and `LoopbackStream` already
promise: mono float32 frames of exactly `FRAME_SAMPLES` at `SAMPLE_RATE`. Reads from the socket the
Swift capture serves.

**The idle-versus-dead distinction is the whole design.** The socket is the liveness signal.
Connected means any gap is a quiet desktop, so real silence is yielded and level reporting stays
alive, which keeps the stall warning honest. Closed means capture has genuinely stopped and the
loop ends. `CONTEXT.md` records the Windows build getting this wrong in both directions, which is
why it is carried over so carefully.

Both shutdown paths use `put_nowait`, not `put`. A blocking put deadlocks whenever the queue is
full, which it routinely is during a decode. See
[12.9](#129-pcmsocketstream-deadlocked-on-shutdown).

### 7.4 The WhisperKit service

`whisperkit-service/`, a SwiftPM executable. **Not** a dependency of the app target, for two
reasons: it can be built with the Command Line Tools alone, so the engine does not become the one
part of the project that needs Xcode; and while the pipeline is Python, the decode has to be
reachable from Python, which a library linked into the app is not.

It speaks a framed protocol over **stdin and stdout**, not a socket. A listener is a port to bind,
a lifetime to manage, and, if the bind is wrong, an open door on the network — the system audio
path made that mistake once already. A pipe has none of them, and the service exits when its
parent closes stdin, which is exactly the lifetime wanted.

Framing is a little-endian `uint32` length, a JSON header, then the audio bytes the header
declares. Replies are a length and a JSON body.

| Op | Purpose |
|---|---|
| `available` | Are the Core ML weights for this variant already here? |
| `prepare` | Download them, emitting progress frames, then a terminal frame |
| `load` | Load a model. Reports which compute units it got |
| `transcribe` | Decode audio, returning text, `avg_logprob` and word probabilities |

Progress arrives as frames *ahead* of the terminal one, so a caller reads until it sees a frame
without `progress` on it.

`ModelComputeOptions` is left at its defaults, which send the mel and encoder to the GPU and the
text decoder to the Neural Engine. **That is the whole point of the service**, and it is also what
makes it scale to hardware nobody here owns: Core ML routes to whatever the machine has, so a
faster Mac is used more without a line of code changing.

---

## 8. The wire protocol

The app and the engine speak JSON over a WebSocket on 8766. The engine also serves `/devices.json`
over HTTP on 8765.

**The schema has exactly one declaration**, in `tests/test_protocol_contract.py`, and
`tests/test_swift_protocol.py` checks `Protocol/Events.swift` against it in both directions:
sixteen event types, forty-one wire fields, ten commands, and the eight-field device list. Neither file may
grow its own copy. Two declarations of one contract drift, and drifting silently is the exact
failure being guarded against — a wire name that differs by an underscore compiles cleanly in Swift
and then decodes to nil, which on a caption means a line with no speaker and no clarity, so the
feature looks broken rather than misspelt.

Events, grouped by what they do:

| Event | Carries |
|---|---|
| `status` | `state`, `running`, `model`, `device` |
| `partial`, `final` | `id`, `text`, `speaker`, `clarity`, `words` |
| `discard` | `id`, when a provisional line is withdrawn |
| `speech_start` | Nothing visual today; kept for latency work |
| `level` | `rms`, `db`, `speech_prob`, `speaking` — about 10 Hz |
| `roster` | The speaker list |
| `speaker_merged`, `speaker_deleted` | Always *before* the roster reflecting them |
| `model_required`, `model_catalog` | The catalogue, with per-machine lag estimates |
| `download_started`, `download_progress`, `download_complete`, `download_failed` | Model downloads |
| `error` | `message`, `code`, `running` |

Commands go the other way: `toggle`, `start`, `stop`, `list_models`, `download_model`,
`rename_speaker`, `set_self`, `merge_speakers`, `delete_speaker`, `reset_speakers`.

The app adds one problem code the engine never sends: **`screen_denied`**, raised by
`TranscriptStore.reportProblem` when ScreenCaptureKit is refused. The engine cannot report it
because on macOS the engine never touches system audio.

---

## 9. The engine story

This is the largest single decision in the port and it was settled by measurement rather than
preference. The full argument is in `docs/MACOS-PORT.md`; this is the narrative.

### 9.1 Where it started

The repository arrived with `BackendHost.swift` launching the existing Python engine as a child
process. That was deliberate and documented as temporary: it puts real captions on screen before
the native engine decision is taken, so the interface can be finished and judged while the
measurement is still outstanding. The port doc gated everything on it — *"phase 1 does not start
until phase 0 has measured a decode time"* — and that measurement had never been taken.

### 9.2 What the measurement said

CTranslate2 publishes `macosx_11_0_arm64` wheels, so faster-whisper installs and runs on Apple
Silicon. **It runs on the processor only.** There is no Metal backend and no Neural Engine
backend; the pull request that would add one has been open and unmerged since July 2026.

Measured on an M1 Max, six seconds of speech, CPU int8, at beam 5 with word timestamps — which is
what `asr.py` actually asks for on a final:

| Model | Decode | Against a 1000 ms budget |
|---|---|---|
| `base` | 698 ms | Clears it |
| `small` | 1177 ms | Does not |
| `medium` | 2683 ms | 2.7× over |
| `large-v3` | 4684 ms | 4.7× over |

The port doc's exit criterion was whether CPU-only CTranslate2 clears `small`. **It does not**, and
that is on the faster of the two intended machines, plugged in. By the doc's own reasoning the
rewrite therefore buys "considerably more" than the marginal case.

### 9.3 The hardware question, answered with a curve

The obvious response is a bigger Mac. It does not work, and the reason is worth keeping.

Thread scaling for `large-v3` on the same machine:

| Threads | Decode | Gain over the previous |
|---|---|---|
| 2 | 7251 ms | — |
| 4 | 4924 ms | 1.47× |
| 8 | 3989 ms | **1.23×** |

Each doubling buys less than the last, because Whisper's decoder is autoregressive — it generates
one token at a time and cannot be parallelised. Only the encoder scales. Extrapolating, 8→16 cores
is worth roughly 1.12× and 16→32 about 1.06×.

Applied to real hardware:

- **Mac Pro** (discontinued March 2026, stuck on M2 Ultra: 24 cores, 16 of them performance):
  roughly **3 s** for `large-v3`. Still three times over budget.
- **Mac Studio M3 Ultra** (24 performance cores, Apple's claimed 1.5× CPU): roughly **2.2 s**.
- **M5 Max** (18 cores, 6 "super" at 4.6 GHz plus 12 performance): roughly **1.3–2.0 s** on the
  processor. Better, still not real-time for `large-v3`.

**The machine was never the constraint.** On any of those, CTranslate2 leaves the GPU and the
Neural Engine completely idle. An M5 Max claims eight times the AI compute of an M1 Max and the
old engine could reach none of it. Each generation makes the engine choice cost *more*.

### 9.4 What WhisperKit did

`whisperkit-service/` was built to test this, and it settled it. Same six seconds, same machine:

| Model | CTranslate2, processor | WhisperKit, GPU and ANE | Gain |
|---|---|---|---|
| `base` | 698 ms | **136 ms** | 5.1× |
| `small` | 1177 ms | **370 ms** | 3.2× |
| `medium` | 2683 ms | **1362 ms** | 2.0× |
| `large-v3` | 4684 ms | **2497 ms** | 1.9× |

**The phase 1 gate passes.** `small` moves from over budget to comfortable on a machine where the
processor path cleared neither it nor anything above it.

Three findings fell out of building it, all of which improve the position:

1. **WhisperKit no longer forces macOS 14.** The package moved to
   `argmaxinc/argmax-oss-swift` (MIT) and declares `.macOS(.v13)`. The port doc's statement that
   *"this sets the floor at macOS 14, since that is WhisperKit's minimum"* is **out of date**. The
   13.3 floor survives the engine change. The 14.4 argument still holds for the Core Audio tap,
   separately.
2. **Core ML spreads the work by default.** No hardware tier to write.
3. **It builds with the Command Line Tools.** SwiftPM ships with them.

### 9.5 What it cost

One shipped feature. See [13.1](#131-the-clarity-score).

---

## 10. Every measurement taken

All on the machine in [section 16](#16-environment-what-this-was-built-on), on AC power. **The
port doc also asks for battery figures and they have not been taken.**

### 10.1 Decode latency, both engines

Six seconds of speech generated with `say`, decoded at beam 5 with word timestamps.

| Model | CTranslate2 (CPU int8) | WhisperKit (Core ML) |
|---|---|---|
| `base` | 698 ms | 136 ms |
| `small` | 1177 ms | 370 ms |
| `medium` | 2683 ms | 1362 ms |
| `large-v3` | 4684 ms | 2497 ms |

At the *shipped tables'* own methodology — beam 1, no word timestamps — CTranslate2 gave 305 ms,
893 ms, 2242 ms and 4085 ms. The two columns differ by roughly two, which is why the picker's
figures cannot be compared with the app's behaviour directly.

### 10.2 What the model picker claims

| Model | Picker estimate | Measured (WhisperKit) | Measured (CPU) |
|---|---|---|---|
| `large-v3` | 842 ms | 2497 ms | 4684 ms |
| `distil-large-v3` | 732 ms | not measured | not measured |
| `medium` | 505 ms | 1362 ms | 2683 ms |
| `small` | 194 ms | 370 ms | 1177 ms |
| `base` | 98 ms | 136 ms | 698 ms |
| `stream-en` | 26 ms | n/a | works |
| `stream-en-kroko` | 23 ms | n/a | works |

`hardware.py` scales its tables by a measured `cpu_score`. This machine scores **377.9** against a
`_REFERENCE_CPU_SCORE` of **73.0**, so every entry is multiplied by 0.193. The probe is a BLAS
matmul benchmark, which Accelerate is extremely good at and which says nothing about int8
transformer decode.

### 10.3 The clarity signal, both engines

`small`, three clips, `_clarity_from_logprob` applied to each engine's `avg_logprob`.

| Clip | WhisperKit | faster-whisper | Clarity shown | Lowest word probability |
|---|---|---|---|---|
| clean | −0.0625 | −0.2008 | **100** vs 89 | 0.530 vs 0.457 |
| noisy | −0.0792 | −0.2193 | **100** vs 87 | 0.560 vs 0.544 |
| very noisy | −0.5667 | −1.0877 | **48** vs 0 | 0.070 vs 0.080 |

WhisperKit's figure is consistently a third to a half of faster-whisper's magnitude. Word
probabilities are closer but drift the same way — fewer words fall below 0.55.

**Three synthetic clips on one model. Enough to prove the shift, not enough to calibrate against.**

### 10.4 Hallucination suppression

Two seconds of low-amplitude noise, `large-v3`, WhisperKit:

| Guards | Decode |
|---|---|
| Without `no_speech_threshold`, `log_prob_threshold`, `compression_ratio_threshold` | **110.2 s** |
| With them | **4.0 s** |

Whisper decodes noise into invented sentences and runs to the token limit doing it. `warmup()`
feeds it exactly that, which is what made the app appear to hang on "Loading the model".

### 10.5 Model load times

Both about 2 s once the Core ML weights are cached, `base` and `large-v3` alike. First use of a
variant downloads weights — gigabytes for the larger ones — and that download is now reported.

### 10.6 System audio

The PCM transport was verified with a synthetic tone rather than by ear: a 440 Hz tone at
amplitude 0.25 arrived at 440 Hz and 0.25, in frames of exactly `FRAME_SAMPLES` float32, and an
idle sender produced silence frames rather than stopping. Speech played through the speakers was
then captioned end to end.

---

## 11. Decisions, including the ones that were reversed

### 11.1 Reversal: the engine was a submodule, now it is vendored

**First position.** `desigrit/sunno` carried as a pinned submodule at `external/sunno`. Two
reasons: the first milestone runs the existing Python engine, and two tests read the backend's
source to check this client against it. The pin was deliberate — a green test meant agreement at
*that commit*, and bumping it was a reviewable act.

**Reversal.** The second reason did not survive contact with the first. System audio needed the
engine changed, which meant a commit in the other repository, a pin bump here, and a client branch
nobody could clone until the engine branch landed.

**Current position.** Vendored. The protocol test is *stronger* for it, because it now pins the
Swift against the engine that will actually run rather than a commit somebody remembered to bump.
Only the theme parity check still wants the Windows tree, and it skips loudly without it.

### 11.2 Reversal: the model picker was a disclosure, then a pop-up button, then a disclosure

**First position.** A `DisclosureGroup` holding seven radio rows.

**Reversal.** The Human Interface Guidelines put the boundary between radio rows and a pop-up
button at about five options, and seven were crammed into a 232-point sidebar. Changed to a menu.

**Reversal again.** The comparison *is* the point on that screen — a menu hides six options behind
one. Back to radio rows, which show every model's cost side by side.

**What was actually broken** was neither: the click target. A `DisclosureGroup` on macOS wires only
its chevron to the binding, so the header could be opened only by hitting a triangle a few points
across. The header is a `Button` now and the whole band responds.

### 11.3 The engine: CTranslate2 to WhisperKit

Settled by [section 9](#9-the-engine-story). CTranslate2 remains as a fallback and `--engine ct2`
still selects it, which is what makes an A/B possible on one machine.

### 11.4 System audio: ScreenCaptureKit, not the Core Audio tap, not a virtual device

**Virtual device (BlackHole) ruled out.** It works by becoming the system output, so hearing the
audio at the same time requires building a Multi-Output Device by hand in Audio MIDI Setup. Get it
wrong and sound stops reaching the hearing aid. Asking a hard-of-hearing user to hand-configure the
audio route their hearing depends on, where the failure mode is silence, is not a trade this app
should offer.

**ScreenCaptureKit over the Core Audio tap**, for now. The tap has the honest prompt and needs
macOS 14.4; ScreenCaptureKit works two versions further back, is known to be allowed in the App
Sandbox, and does not block on a DTS answer nobody outside Apple can give. The cost is the wrong
noun on the permission prompt, which the app defuses by explaining itself before the system asks.

The seam exists, so adding the tap later is cheap.

### 11.5 Settings is a separate window

The one deliberate departure from the Windows shape. Windows uses a full-window page with a back
arrow; Cmd-comma has to open *something* on macOS, and keeping the page would be the most obviously
non-native thing left in the app.

### 11.6 No AccentColor asset

Deliberately absent. Without one, `Color.accentColor` follows the system accent the user chose,
which is what the Windows build does. Defining one in the brand teal would override that
everywhere and make the transport button ignore a preference somebody set on purpose. The teal
lives in `Theme.ink` and is used only for the mark and the badges.

### 11.7 The transcript is AppKit

See [7.2](#72-the-swift-app). Hover hit-testing, which SwiftUI cannot do.

### 11.8 Signing with a real identity, even for development

`project.yml` already said so and the machine proved it. See
[12.7](#127-an-ad-hoc-signature-loses-tcc-grants-on-every-rebuild).

---

## 12. Bugs found, and the lesson from each

The Swift in this repository had never been compiled. The first build found **one** error. Running
it found the rest. They are recorded here because most of them are a *class* of bug rather than a
typo, and the class is what will bite again.

### 12.1 The one compile error

`FirstRunView.swift`: a ternary mixing `.secondary` (a `HierarchicalShapeStyle`) with `.orange` (a
`Color`). Fixed by naming both types.

**Lesson:** the compiler catches almost nothing that matters in SwiftUI. One error in 2,400 lines,
and six behavioural bugs behind it.

### 12.2 The engine was orphaned on any exit but a clean stop

A child outlives its parent on Unix. An orphaned engine holds the microphone and both ports, so the
next launch failed to bind and **quietly attached to the stale process instead** — which presents
as a working app showing state that stopped updating. A model downloaded a minute ago still listed
as missing.

**Lesson:** the failure was not a crash. It was an app that looked fine and had stopped keeping up
with reality. Those are the expensive ones.

### 12.3 `BackendHost.status` was never rendered anywhere

Three carefully written failure messages — missing engine, missing venv, engine stopped — reached
only `diagnosticsReport()`. A backend that never started left the window saying "Starting the
speech engine" indefinitely.

**Lesson:** a well-written error message that nothing displays is not an error message.

### 12.4 Captions rendered at zero height

`CaptionTextView` wraps an `NSTextView`, which has no useful intrinsic height outside the
`NSScrollView` it is built to live in. Every row laid out at nothing. **The transcript looked blank
while the events were arriving perfectly**, and the empty state did not appear either, because
`lines` was not empty.

Found by watching the WebSocket and confirming the store had the text, then by instrumenting
`TranscriptStore` to print `lines.count`.

**Lesson:** when the data is right and the screen is wrong, measure the view, not the data. And
anything hosted from AppKit must be asked how big it is.

### 12.5 The false engine-stopped banner

`Process.terminationHandler` runs on a background queue. A deliberately replaced engine reported
its own SIGTERM *after* its replacement was already running, overwriting a healthy status with
"stopped unexpectedly (exit 15)" — exit 15 being SIGTERM, the signal `BackendHost` sends itself.
The message never cleared, because nothing starts an engine again once one is running.

Fixed by guarding on **process identity** rather than a "we are stopping" flag, which is read too
late.

**Lesson:** a flag that describes intent races with a callback that describes the past. Compare
identities.

### 12.6 `startUp()` ran on every `onAppear`

And `startUp()` replaces the engine. So the model never finished loading, and no caption ever
arrived. It looked exactly like captions being broken.

**Lesson:** `onAppear` is not "once". Anything expensive behind it needs a claim.

### 12.7 An ad-hoc signature loses TCC grants on every rebuild

`project.yml` warns about this in a comment and the machine proved it:
`Failed to match existing code requirement for subject com.desigrit.sunno`. An ad-hoc signature
pins the requirement to the binary's own hash, so every rebuild invalidates it. Screen recording
then fails silently and reads as a permissions bug that is not one.

Fixed by signing with a self-signed development certificate, because the requirement then keys to
the *certificate*.

### 12.8 The capture socket was open to the network

`NWListener(using: .tcp, on: .any)` reads as "any port" and is also any **address**. While system
audio was being captured, anyone on the same Wi-Fi could open that port and receive raw PCM of
whatever the Mac was playing.

In an app whose one promise is that the conversation never leaves the machine, this was the worst
bug in the tree. Found by an independent review pass, not by testing. It now binds `127.0.0.1`
explicitly, and that was verified by inspecting the socket rather than by reading the code.

**Lesson:** run a reviewer over anything that binds, and check the socket, not the source.

### 12.9 `PCMSocketStream` deadlocked on shutdown

Both shutdown paths called blocking `queue.put(None)`. The queue is routinely full during a decode,
because nothing drains it for hundreds of milliseconds. Pausing mid-decode wedged the capture pump
permanently, and everything afterwards silently did nothing.

Fixed with `put_nowait`. The consumer already leaves on `is_alive` going false, so the sentinel is
only an early wakeup and dropping it is safe.

### 12.10 The hallucination guards were not passed to WhisperKit

`asr.py` hands faster-whisper three thresholds from `config.py`. The WhisperKit path handed it
none. Two seconds of noise took **110 seconds**, and `warmup()` feeds it exactly that.

**This was never only a warmup problem.** Every silence in a real conversation would have hit it.

**Lesson:** when you reimplement an engine behind an existing interface, the interface is not the
contract. The *parameters the old one was given* are part of the contract too.

### 12.11 Availability was asked of the wrong engine

`models.is_available` answers for the CTranslate2 weights. WhisperKit needs Core ML weights, a
different artifact in a different place. The app saw a model it already had, went straight to
loading, and showed a static "Loading the model" while gigabytes downloaded behind it with no
progress and no end.

### 12.12 Weights landed in `~/Documents/huggingface`

WhisperKit's default `downloadBase`. Five gigabytes in the folder somebody keeps their own files
in, with nothing there to explain what put it there.

### 12.13 Three path defects inherited from Windows

`paths.data_dir()` had no macOS branch and returned `~/.sunno`, a Linux convention.
`models._stream_root()` and `_onnx_root()` read `LOCALAPPDATA` and fell back to the home directory,
so streaming and ONNX models landed in a bare `~/Sunno`. All three now resolve under
`~/Library/Application Support/Sunno`. **Windows paths were verified unchanged** by simulating
`win32`.

### 12.14 Smaller ones

- The settings window flickered, because level events at 10 Hz invalidated every observer of
  `TranscriptStore`.
- The model picker could only be opened by its chevron.
- A model chosen from the sidebar was not persisted; the capture device was not persisted at all.
- The two bottom sections did not line up, because nothing enforced a common height across the
  split.
- There was no app icon: the asset catalogue listed ten entries and contained no images.
- Compact mode ignored `CONTEXT.md`'s rule about refusing to hide the setup screen.
- A `var` captured across `NWListener`'s queue guarded a checked continuation against double
  resume — which is a fatal error, so the guard was itself a data race.

---

## 13. What is parked, and what it costs

Each of these is a deliberate decision to stop, not an oversight. They are listed with what it
costs to leave them, so the next person can weigh them rather than rediscover them.

### 13.1 The clarity score

**State:** `WhisperKitEngine` returns `clarity=None`. The badge does not appear on the default
engine.

**Why:** WhisperKit's `avgLogprob` distribution differs from faster-whisper's by a factor of two to
three ([10.3](#103-the-clarity-signal-both-engines)). Pushed through the existing
`_clarity_from_logprob` it reads **100 where Windows reads 89**, and **48 where Windows reads 0**.
That number tells a hard-of-hearing user whether they were heard. An optimistic one is worse than
none.

**Why parking is clean:** `Transcript.clarity` was already `Optional` and the UI already treats it
as such — the streaming transducers report `None` and three surfaces say "Whisper models only"
because of it. So this engine simply behaves like the lean tier.

**What it costs:** a shipped feature is invisible on macOS. Somebody coming from the Windows build
will notice. The README says so plainly.

**To unpark:** build a calibration set of real speech across the quality range, decode it through
both engines, and re-derive both `_clarity_from_logprob` and the `low_confidence_below = 0.55` word
threshold. Three synthetic clips proved the shift; they cannot calibrate it.

### 13.2 The model picker lies

**State:** the delay estimates come from `hardware.py`'s tables, scaled by a `cpu_score` that has
never seen Apple Silicon and never seen Core ML.

**How wrong:** now wrong in **both** directions. Too optimistic about `large-v3` (says 842 ms,
decodes in 2497 ms) and too pessimistic about what the Neural Engine does with the small ones (says
194 ms for `small`, which decodes in 370 ms but was quoted against a CPU baseline of 1177 ms).

**The sharp end:** `hardware.default_model` scans the catalogue best-accuracy-first and takes the
first entry marked responsive. Every entry is marked responsive. **So a Mac defaults to
`large-v3`** — a 3 GB download that does not keep up.

**Explicitly accepted for now.** The README warns users and gives the real table.

**To fix:** populate a macOS lag table from measurement, or better, let `record_latency` learn per
machine and stop shipping a table at all. The machinery to adapt per machine already exists; only
the numbers are wrong.

### 13.3 `add_context` is ignored

`CTranslate2Engine` feeds recent text back as Whisper's `initial_prompt`, which helps continued
sentences. WhisperKit takes prompt *tokens* rather than a string, so carrying it across means
tokenising on the Swift side. Left out rather than half-done, and marked in the source.

**Cost:** a little accuracy on sentences that continue a thought.

### 13.4 Speaker labelling is off in this checkout

The engine reports:

```
Speaker labelling: off (speaker embedding model not found:
  .../models/speaker-embedding-campplus-en.onnx)
```

The 28 MB CAM++ model is not in this repository. `speaker.py` and the whole roster path are intact
and the protocol carries speakers; there is simply no model to embed with. The Windows package
ships it.

**To fix:** vendor the model, or download it on first run the way the Whisper weights are.
`sherpa-onnx` exposes the extractor and produces the same 512-dimensional vector the existing
`speakers.json` profiles are built from, so saved speakers stay valid.

### 13.5 Distribution

Undecided, and deliberately so. The App Sandbox is off, notarisation has not been attempted, there
is no update mechanism, and `project.yml` still carries
`com.apple.security.cs.disable-library-validation` — which is needed only while an interpreter with
unsigned C extensions is being launched, and which is the single entitlement that most reliably
closes the App Store door.

Deleting Python is what makes the App Store possible again. That is now closer than it was: the
decode is already Swift.

### 13.6 Battery measurements

Every figure in this document is on AC. The port doc asks for battery figures because it wants the
shipped tier decided on a machine on battery, and `ARM-PORT.md` measured power mode as worth about
1.6× on the other port.

### 13.7 The other repository's branch

`desigrit/sunno` branch `macos-system-audio` is unmerged. See [section 4](#4-the-two-repositories).

---

## 14. What to do next

Ordered by value per unit of effort, with the reasoning.

### 14.1 Calibrate clarity, then unpark it

**Why first:** it is the only *shipped feature that is currently invisible*, the work is bounded,
and the measurement infrastructure already exists (`whisperkit-service` returns `avg_logprob` and
word probabilities on every decode).

**What it needs:** real speech across the quality range — clean, across a room, over a call, with
background noise — decoded through both engines, and both constants re-derived. The Windows repo
has test clips.

### 14.2 Make the picker tell the truth

**Why:** a Mac currently defaults to a model that cannot keep up, on the one screen where being
wrong costs trust — somebody deciding whether to spend a 3 GB download.

**Two options.** Populate a macOS table from measurement, which is quick and goes stale; or let
`record_latency` learn from real decodes and quote what this machine has actually done, which is
slower to build and never goes stale. The second is the better answer and the machinery is half
there already.

### 14.3 Ship speaker labelling

Vendor or download the CAM++ model. Everything else is intact.

### 14.4 Battery measurements

Cheap, and it is what the port doc says the shipped tier should be decided on.

### 14.5 Carry `add_context` across

Tokenise on the Swift side and pass prompt tokens. Recovers a little accuracy on continued
sentences.

### 14.6 Consider deleting the Python engine

The decode is already Swift. What remains in Python is the pipeline — VAD, endpointing, the
two-pass discipline, speaker matching, hallucination suppression. Porting it is the "quarters, not
weeks" work the port doc describes, and it buys: no interpreter in the bundle, no
`disable-library-validation`, the App Store door open, and one process instead of three.

**Do not start this without a reason.** The current shape works, and the pipeline is the most
carefully tuned code in either repository.

### 14.7 The Core Audio process tap

macOS 14.4 and later. The honest prompt, and it may matter more than that: there is an unconfirmed
report that ScreenCaptureKit on macOS 26 sums system audio to mono or drops a channel when an
external interface is in use, which would land squarely on the hearing aid route. The capture seam
exists, so adding it is contained.

---

## 15. Landmines

Things that will bite, in roughly the order somebody new will hit them.

**Screen recording never prompts.** macOS returns a denial and adds the app to Privacy & Security
silently — the TCC log says `Service kTCCServiceScreenCapture does not allow prompting; returning
denied`. Somebody waiting for a dialog waits forever. The app says so and names the pane and the
relaunch. If system audio "does not work", check that switch first.

**A rebuild can invalidate the grant.** If you sign ad-hoc, every rebuild does. Even with a stable
certificate, deleting and recreating the bundle has been observed to lose it; toggle it off and on
in Privacy & Security.

**`~/Library/Application Support/Sunno` holds gigabytes.** Whisper Core ML weights, streaming
models, ONNX models, `hardware.json`, `speakers.json`. Deleting it is safe but re-downloads
everything.

**The engine's stdout is discarded by the app.** Deliberately — it prints latency and speaker ids
but never transcript text, and inheriting would put it in the system log. When you need to see it,
run the engine yourself.

**`whisperkit-service` speaks a framed protocol on stdout.** Anything that prints to stdout inside
that process corrupts the stream. If you add logging, send it to stderr.

**SwiftPM and `safe.bareRepository`.** SwiftPM keeps checkouts as bare repositories, and git
refuses to read them when `safe.bareRepository` is `explicit`, which it is on this machine. The
setup script overrides it through the environment for that command only rather than writing to
anybody's global config.

**Do not delete the Windows-only files in `server/`.** `loopback.py` and `cuda_setup.py` are inert
here and are kept so the two copies of the engine stay easy to diff.

**Do not let either contract test grow its own copy of what it checks.** The protocol test imports
the schema; the theme test reads the Windows XAML. Two declarations of one contract drift, and
drifting silently is the exact failure they exist to catch.

**The lag tables fail quietly for unknown model ids**, falling through to
`_UNKNOWN_MODEL_LAG_MS = 5000`, so the picker shows every model as "5 s, not responsive". The ARM
port hit exactly this.

**Compact mode's minimum size ordering.** Lower before shrinking, raise after expanding. The other
way round and the window silently refuses.

---

## 16. Environment: what this was built on

| | |
|---|---|
| Machine | MacBook Pro, **Apple M1 Max**, 8 performance + 2 efficiency cores, 32 GB |
| macOS | 15.5 (24F74) |
| Xcode | **None.** Command Line Tools only, at `/Library/Developer/CommandLineTools` |
| Swift | 6.1.2, used in Swift 5 language mode |
| Python | 3.9.6, the Command Line Tools one |

**`xcode-select -p` fails on this machine** — there is no active developer directory. Everything
works with `export DEVELOPER_DIR=/Library/Developer/CommandLineTools`, and every build and test
command in this project was run that way.

### Building without Xcode

The documented path is XcodeGen, which needs Xcode. Because this machine has none, the app was
built throughout with a script that:

1. Compiles every Swift file with `swiftc` against the macOS SDK, targeting `arm64-apple-macos13.3`.
2. Writes an `Info.plist` reproducing `project.yml`'s `info.properties` by hand.
3. Writes the entitlements from `project.yml`'s `entitlements.properties`.
4. Builds `Sunno.icns` from the committed icon PNGs with `iconutil`, because compiling an asset
   catalogue needs `actool`, which ships with Xcode.
5. Signs with a **self-signed development certificate**, not ad-hoc, so TCC grants survive
   rebuilds.

**That script is not committed.** It hardcodes a path and a certificate name and duplicates
`project.yml`, which would rot. If you are also without Xcode, it is a forty-line script and the
five steps above are the whole of it. If you have Xcode, use XcodeGen and ignore this.

The self-signed certificate was made with:

```bash
openssl req -x509 -newkey rsa:2048 -keyout k -out c -days 3650 -nodes \
  -subj "/CN=Sunno Local Dev" -addext "extendedKeyUsage=critical,codeSigning"
```

then imported into the login keychain and referenced by its SHA-1. Shipping still needs a real
Developer ID.

### GitHub access

Both repositories belong to **`desigrit`**. The `gh` CLI on this machine is logged in as `desigrit`
in the keychain, but a `GH_TOKEN` environment variable is injected that shadows it and belongs to a
different account with no push rights. Pushes therefore need:

```bash
env -u GH_TOKEN /usr/bin/git \
  -c credential.helper= \
  -c "credential.https://github.com.helper=!/path/to/gh auth git-credential" \
  push origin main
```

`-c credential.helper=` matters: there is a `copilot` credential helper configured that otherwise
wins and supplies the wrong account.

---

## 17. How to verify you have not broken anything

In rough order of cost. Run all of them before pushing anything substantial.

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

# 1. The Swift compiles, with no warnings. Warnings here have twice been real bugs.
swiftc -typecheck -swift-version 5 -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos13.3 $(find Sunno -name '*.swift' | sort)

# 2. The wire types still agree with the engine.
python3 tests/test_swift_protocol.py

# 3. The palette still agrees with the Windows app. Skips loudly without a checkout.
python3 tests/test_theme_parity.py
SUNNO_WINDOWS_REPO=/path/to/sunno python3 tests/test_theme_parity.py

# 4. The engine imports and reports which speech engine it will use.
./scripts/setup-engine.sh

# 5. The engine runs standalone and reaches "Listening."
./.venv/bin/python -m server.app --model small
```

Then the behavioural checks, which nothing automated covers:

- Launch the app. It should reach captions without you doing anything.
- Speak, or run `say "the quick brown fox"`. Partials should stream and a final should replace
  them.
- Switch the device to **System audio (this Mac)** and play something. Captions should follow.
- Quit with Cmd-Q. **No `server.app` or `whisperkit-service` process should survive.** Check with
  `ps aux | grep -E "server.app|whisperkit-service"`.
- `kill -9` the app, then relaunch. The orphaned engine should be reaped, and exactly one engine
  should be running.
- Open Settings while audio is playing. The tab bar should not flicker.

And the check that would have caught the worst bug in section 12:

```bash
# While system audio is capturing: the listener must be on 127.0.0.1, never *
lsof -nP -p $(pgrep -f "Sunno.app/Contents/MacOS/Sunno") | grep LISTEN
```

---

## 18. File index

### The app

| Path | What it is |
|---|---|
| `Sunno/SunnoApp.swift` | Entry point, wiring, menu bar, the diagnostics allow-list |
| `Sunno/Theme.swift` | Palette and numeric rules, mirrored from the Windows app, pinned by a test |
| `Sunno/Protocol/Events.swift` | Wire types, pinned by a test |
| `Sunno/Services/BackendHost.swift` | Owns the Python process, and does not orphan it |
| `Sunno/Services/CaptionClient.swift` | The WebSocket, with an indefinite reconnect ladder |
| `Sunno/Services/SystemAudioCapture.swift` | ScreenCaptureKit, conversion, loopback PCM socket |
| `Sunno/Services/DeviceCatalog.swift` | Device list, plus the synthetic system-audio entry |
| `Sunno/Services/AppSettings.swift` | Preferences and the two window geometries |
| `Sunno/Models/TranscriptStore.swift` | Lines, speakers, status, assembled from events |
| `Sunno/Models/AudioMeter.swift` | The level, split out because it moves at 10 Hz |
| `Sunno/Models/SessionClock.swift` | The conversation timer and the stall warning |
| `Sunno/Views/*.swift` | The interface |
| `Sunno/Windowing/WindowChrome.swift` | Window level, minimum size, the two saved frames |

### The engine

| Path | What it is |
|---|---|
| `server/app.py` | Process entry, WebSocket and HTTP, the capture pump, model downloads |
| `server/pipeline.py` | Endpointing, the two-pass discipline, level publishing |
| `server/engine.py` | The `SpeechEngine` protocol, `Transcript`, engine resolution |
| `server/asr_whisperkit.py` | **New.** Core ML decode through the Swift service |
| `server/asr.py` | CTranslate2, the processor fallback |
| `server/asr_stream.py` | sherpa-onnx transducers |
| `server/pcm_socket.py` | **New.** System audio from the app, over a socket |
| `server/audio.py` | Microphone capture |
| `server/loopback.py` | WASAPI. **Inert on macOS**, kept for diffability |
| `server/config.py` | Every tunable, with the reason beside it |
| `server/models.py` | The catalogue and downloads |
| `server/paths.py` | Where things are written. Gained a `darwin` branch |
| `server/hardware.py` | Machine measurement and the lag tables that are wrong here |

### Everything else

| Path | What it is |
|---|---|
| `whisperkit-service/` | The Swift decode service |
| `scripts/setup-engine.sh` | Creates the venv, builds the service, reports the engine |
| `requirements-macos.txt` | The subset of the Windows requirements that resolves here |
| `tests/test_swift_protocol.py` | Swift wire types against the engine |
| `tests/test_protocol_contract.py` | The single declaration of the schema |
| `tests/test_theme_parity.py` | Palette against the Windows app; skips without it |
| `docs/MACOS-PORT.md` | The decision record, and what is still unverified |
| `docs/macos-mockup.html` | The approved interface |
| `docs/HANDOVER.md` | This file |
| `project.yml` | The Xcode project, as forty lines of reviewable YAML |

---

## Closing note

The two things most likely to be re-derived by somebody who does not read this:

1. **CTranslate2 cannot use the GPU or the Neural Engine on macOS, and no amount of hardware fixes
   it.** The curve in [9.3](#93-the-hardware-question-answered-with-a-curve) is the argument.
2. **WhisperKit's confidence numbers are not faster-whisper's.** They look close enough to trust
   and they are not; [10.3](#103-the-clarity-signal-both-engines) is the measurement.

And the one thing most likely to be broken by somebody tidying up: the comments explaining *why*.
Several of them are the only record of a bug that took hours to find.
