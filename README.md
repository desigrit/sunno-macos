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

## Installing

Apple Silicon, macOS 13.3 or later.

**[Download Sunno for macOS](https://github.com/desigrit/sunno-macos/releases/latest)** — about
80 MB. Unzip it and drag **Sunno** to your Applications folder. It carries its own Python and
speech service, so there is nothing else to install.

**The first time you open it, macOS will refuse.** It will say Sunno "cannot be opened because
Apple cannot check it for malicious software", which means only that this build is not notarised.
To get past it:

1. **System Settings → Privacy & Security**
2. Scroll to the bottom. There is a line about Sunno being blocked, and a button: **Open Anyway**
3. Open Sunno again

You only do that once. There is no way around it short of an Apple Developer Program membership,
and macOS 15 removed the Control-click shortcut that used to skip it. If you would rather not
trust a build you cannot verify, that is a reasonable position — the source is all here, and
[building it yourself](#building) takes a few minutes.

**Two permissions.** Sunno asks for the microphone the first time you record. For captioning what
your Mac is *playing* — a call, a film, a video — it also needs **Privacy & Security → Screen &
System Audio Recording**, and macOS never prompts for that one. Switch Sunno on there yourself
and reopen it. The app explains this at the point you need it.

**Then pick a model**, which downloads it. `small` is the one to choose: accurate enough for most
rooms and comfortably ahead of the conversation. The first launch after a download sits on
"Loading the model" for a minute or so while Core ML compiles it for your particular Mac. That
happens once per model and never again.

## Building

```bash
git clone https://github.com/desigrit/sunno-macos.git
cd sunno-macos
./scripts/setup-engine.sh          # the Python engine, in a .venv
brew install xcodegen && xcodegen generate && open Sunno.xcodeproj
```

To build the distributable app rather than a development one:

```bash
./scripts/package-app.sh           # -> dist/Sunno.app and the zip beside it
./scripts/publish-release.sh       # -> attaches the zip to the GitHub release
```

`package-app.sh` produces an app that does not need this repository, a `.venv`, Homebrew or even
Xcode's Command Line Tools on the machine that runs it: it downloads a relocatable Python, puts
it inside the bundle with the engine, and signs the whole thing. Speech models stay out of it and
download on first use, which is the difference between an 80 MB download and a 5 GB one.

`publish-release.sh` replaces the asset on an existing release rather than making a new one, so
the download link never changes.

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

- **The bigger models still lag, though far less than they did.** Whisper runs through Core ML
  here, so the Neural Engine and the GPU do the work rather than the processor. Measured on an
  M1 Max, decoding six seconds of speech at the settings the app actually uses:

  | Model | Processor | Neural Engine | Keeps up? |
  |---|---|---|---|
  | Whisper base | 0.7 s | **0.14 s** | yes |
  | Whisper small | 1.2 s | **0.37 s** | yes |
  | Whisper medium | 2.7 s | **1.4 s** | no |
  | Whisper large-v3 | 4.7 s | **2.5 s** | no |
  | Zipformer, Kroko | streaming | streaming | yes |

  `small` is the sweet spot: accurate enough for most rooms and comfortably ahead of the
  conversation. `large-v3` is the most accurate on accented speech and you will see it arrive
  late.

  **The delay estimates in the model picker are wrong**, because they are scaled from
  measurements taken on a Windows machine and no Apple Silicon figure has replaced them. They
  are now wrong in both directions: too optimistic about `large-v3`, and too pessimistic about
  what the Neural Engine does with the smaller models. Treat the table above as the real answer.
  [`docs/MACOS-PORT.md`](docs/MACOS-PORT.md) has the measurements behind it.
- **The clarity score is off on this engine.** It is hidden rather than shown wrong: WhisperKit
  reports the confidence Whisper had in a different range from the Windows build, so the badge
  stays away until the mapping is re-derived rather than telling you that you were heard more
  clearly than you were.
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
microphone ─┐                                    ┌─ WhisperKit, on the Neural Engine
            ├─► resample 16 kHz ─► Silero VAD ─►─┤                                  ─► SwiftUI app
system audio┘   (ScreenCaptureKit)               └─ CTranslate2, on the processor
```

A Python engine does capture and recognition. A SwiftUI app displays the results and talks to it
over a local WebSocket. They are separate processes on purpose: a crash in inference leaves the
window alive and reconnecting instead of taking the app down mid-conversation.

| Directory | Contents |
|---|---|
| `Sunno/` | The macOS app: SwiftUI views, the socket, the window chrome |
| `server/` | Python engine: capture, VAD, recognition, speaker labelling |
| `ui/` | Browser client, for the phone or handheld route |
| `whisperkit-service/` | Swift decode service, so Whisper reaches the Neural Engine |
| `scripts/` | Engine setup, packaging, releasing, screenshots |
| `docs/HANDOVER.md` | The full state of the work: what is built, measured, parked and next |
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
