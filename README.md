# Sunno for macOS

**Live captions for the conversation in front of you, running entirely on your own Mac.**

---

## Why this exists

I kept missing things.

Not the big things. I hear those. It is the small ones that go past: the end of a sentence when
someone turns their head, the name of the restaurant, the punchline everyone else laughs at. You
nod along and hope nobody asks a follow up question. If you have done that, you already know why
this app exists.

Sunno means "listen" in Hindi and Urdu.

This is the Mac version of [Sunno](https://github.com/desigrit/sunno), which started on Windows.
Same promises, same shape, a different machine underneath.

## What it does

Point it at a microphone and it writes down what people are saying, as they say it. Put it near
the table at dinner, beside you in a meeting, or pass a small mic to whoever is talking.

- **Captions what your Mac is playing,** which covers video calls, YouTube, podcasts, films.
  There is no equivalent of Windows' loopback capture here, so Sunno uses ScreenCaptureKit and
  explains itself before macOS asks. See [System audio](#system-audio) below.
- **Labels who is speaking.** A four way conversation reads like a conversation instead of one
  long paragraph. Rename anyone, and mark which one is you so your own lines step back.
- **Shows how long you have been recording,** and says "No audio" rather than counting on
  cheerfully when sound stops arriving. A clock that keeps climbing over a dead microphone is
  the one failure this app can least afford.
- **Handles accented speech well**, which is why the engine is Whisper rather than something
  faster.
- **Compact mode**, always on top, adjustable text size, and you can select and copy any part of
  the transcript. Hover an uncertain word to see how confident the model was.

## It runs on your Mac. All of it.

This matters more than any feature.

Captioning apps usually stream your microphone to a company's servers. That means the
conversation at your dinner table, with your family in it, leaves your house. People who have not
thought about it will still feel it, and they are right to.

Sunno does the recognition on your own machine. No account, no sign in, no telemetry, no server
to send anything to. Turn off your Wi-Fi and it works exactly the same. The people around you are
not being uploaded anywhere, and you can tell them so honestly.

The only time Sunno touches the network is downloading the speech model on first run. After
that, never.

Two things it deliberately does not do. Device names never reach a log or the diagnostics
export: a capture device called "Headset (R-Phonak hearing aid)" tells the reader that the user
wears a hearing aid, which is health information arriving through a field nobody thinks of as
sensitive. And the diagnostics report is built as an allow-list rather than a filter, because a
filter has to anticipate every category of secret and an allow-list only emits what somebody
deliberately put on it.

## Requirements

Apple Silicon, macOS 13.3 or later. The first run downloads a speech model.

## Building

There is no installer yet. Build it from source.

```bash
git clone https://github.com/desigrit/sunno-macos.git
cd sunno-macos
./scripts/setup-engine.sh          # the Python engine, in a .venv
brew install xcodegen && xcodegen generate && open Sunno.xcodeproj
```

`project.yml` is the source of truth and the `.xcodeproj` is generated rather than committed: a
pbxproj conflicts on every branch and nobody reviews it, where forty lines of YAML can be read in
a pull request.

**Sign it with a real identity, even for a private build.** macOS ties a permission grant to the
signing identity, so an ad-hoc signature loses its microphone and screen recording permissions on
every rebuild. That reads as a permissions bug and is not one. A self-signed development
certificate is enough, because the grant keys to the certificate rather than to the binary.

Run the engine on its own, which is useful for testing without the app:

```bash
./.venv/bin/python -m server.app --list-devices
./.venv/bin/python -m server.app --model base
```

Two checks run on a bare Python, with no venv and no Xcode. They read text.

```bash
python3 tests/test_swift_protocol.py
python3 tests/test_theme_parity.py
```

The first reads the engine's own source, extracts every event it can emit, and compares that
against `Protocol/Events.swift` in both directions: sixteen event types, forty-one wire fields
and the device list. A wire name that differs by an underscore compiles cleanly in Swift and then
decodes to nil, which on a caption means a line with no speaker and no clarity, so the feature
looks broken rather than misspelt. It does not carry its own copy of the schema and it must not
grow one.

The second compares `Theme.swift` against the Windows app's `App.xaml`. It is the only check here
that needs the other repository, and it reports a skip rather than a pass when there is no
checkout to compare against. Clone `desigrit/sunno` beside this one, or set `SUNNO_WINDOWS_REPO`.

## System audio

macOS has no equivalent of the Windows loopback capture, and it files system audio under the
screen recording permission. So the app says, in its own words and before the system asks, that
it needs that permission because that is where the audio lives and that no picture of your screen
is read or kept.

Two things are worth knowing, because both surprised me:

- **macOS never prompts for screen recording.** It denies the request and adds the app to the
  list in Privacy & Security silently. You have to switch Sunno on there yourself and reopen it.
  The app says so rather than leaving you waiting for a dialog that is not coming.
- Choosing **System audio (this Mac)** in the device menu is all there is to it after that. It
  appears alongside the microphones.

## Honest about what it cannot do

No captioning system is perfect, and anyone who tells you otherwise is selling something.

- **The engine runs on the processor only, and that is the ceiling on this port.** CTranslate2
  has no Metal or Neural Engine backend, so none of the Mac's fast hardware is used yet.
  Measured on an M1 Max, decoding six seconds of speech at the settings the app actually uses:

  | Model | Decode | Keeps up? |
  |---|---|---|
  | Whisper base | 0.7 s | yes |
  | Whisper small | 1.2 s | marginal |
  | Whisper medium | 2.7 s | no |
  | Whisper large-v3 | 4.7 s | no |
  | Zipformer, Kroko | streaming | yes |

  **The delay estimates in the model picker are wrong on Apple Silicon**, in the optimistic
  direction, because they are scaled from measurements taken on a Windows machine. They read
  three to seven times faster than the truth, so the picker will offer you `large-v3` and it will
  not keep up. Choose `base` until this is fixed.
  [`docs/MACOS-PORT.md`](docs/MACOS-PORT.md) explains what a native engine would buy.
- **Microphone placement matters more than the model.** Moving from a distant tabletop mic to a
  close talking one is worth roughly twice the accuracy, which is more than any model change
  available.
- **Speaker labels are best effort.** Short turns like "yeah" or "okay, fine" are left unlabelled
  rather than guessed at, because embeddings need two to three seconds of speech to be
  dependable. Naming the people you talk to most is the single biggest improvement.
- **Overlapping speech degrades badly.** When two people talk at once, single channel recognition
  of any kind struggles.

It is a tool for catching more of what is said, not a court transcript. Used that way, it is
genuinely useful.

## How it fits together

```
microphone ─┐
            ├─► resample 16 kHz ─► Silero VAD ─► Whisper ─► WebSocket ─► SwiftUI app
system audio┘        (ScreenCaptureKit, over a local socket)
```

A Python engine does capture and recognition. A SwiftUI app displays the results and talks to it
over a local WebSocket. They are separate processes on purpose: a crash in inference leaves the
window alive and reconnecting instead of taking the app down mid-conversation.

| Directory | Contents |
|---|---|
| `Sunno/` | The macOS app: SwiftUI views, the socket, the window chrome |
| `server/` | Python engine: capture, VAD, recognition, speaker labelling |
| `ui/` | Browser client, for the phone or handheld route |
| `scripts/` | Engine setup |
| `docs/MACOS-PORT.md` | The decisions, the evidence, and what is still unverified |
| `docs/macos-mockup.html` | The approved interface, screen by screen |

**The engine is vendored here rather than shared.** This repository clones, builds and runs on
its own, with no second checkout and no submodule, because two projects that cannot be built
independently are one project in a trenchcoat. The cost is that `server/` exists in both
repositories, and an improvement that belongs to both is pushed to both. That is a deliberate
trade: a little duplication against a build that never depends on someone else's release.

Some of what is vendored is inert here. `loopback.py` is WASAPI and `cuda_setup.py` is NVIDIA, so
neither runs on a Mac; both are kept so the two copies stay easy to diff.

### Decisions worth knowing before changing things

**The transcript is AppKit, not SwiftUI.** `CaptionTextView` wraps an `NSTextView` because
hovering a word to see how confident the model was needs hit-testing that SwiftUI's `Text` cannot
do. It also has to report its own height, because an `NSTextView` outside a scroll view has none
and every caption lays out at zero.

**Uncertain words carry three signals, not one.** Grey, italic and an underline. Colour alone
would fail Differentiate Without Color, and this is the last app that should lean on hue.

**Settings is a separate window**, because Command comma has to open something on macOS. This is
the one deliberate departure from the Windows shape; the rest is the same.

**Compact mode lowers the window minimum before shrinking, and raises it after expanding.** In
the other order the window silently refuses the resize.

**`speaker_merged` and `speaker_deleted` are handled before the roster that follows them.** The
engine guarantees that ordering deliberately. Handle them the other way round and captions keep
the name of somebody the user just asked the app to forget.

**There is no AccentColor asset, on purpose.** Without one, `Color.accentColor` follows the system
accent the user chose. The brand teal lives in `Theme.ink` and is used only for the mark.

## Licence

MIT. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Sunno is free, and the source is public so you can read exactly what it does with your microphone
rather than taking my word for it.
