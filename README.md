# Sunno for macOS

The native macOS client for [Sunno](https://github.com/desigrit/sunno), an offline live
captioning app. Apple Silicon, macOS 14.4 and later.

**Nothing here has been compiled.** It was written on a Windows machine with no Xcode and no
Apple-platform Swift toolchain, so the first build will find mistakes. What could be verified
without a compiler has been, and there are tests for it: see "What is already checked" below.
Treat the Swift as a careful first draft.

## Clone

The backend is a submodule, so clone recursively:

```bash
git clone --recurse-submodules https://github.com/desigrit/sunno-macos.git
cd sunno-macos
```

If you already cloned without it:

```bash
git submodule update --init --recursive
```

## Build

```bash
brew install xcodegen
xcodegen generate
open Sunno.xcodeproj
```

`project.yml` is the source of truth. The `.xcodeproj` is generated and is not committed: a
pbxproj conflicts on every branch and nobody reviews it, where forty lines of YAML can be read
in a pull request.

## Why the backend is a submodule

This repository holds the client. `desigrit/sunno` holds the Python backend that defines the
protocol, the WinUI app the interface is ported from, and the accumulated project context. The
submodule at `external/sunno` exists for two reasons, and only one of them is temporary.

**The temporary one:** the first milestone runs the existing Python engine as a child process,
so the client has real captions on screen before the native engine decision is taken.
`Services/BackendHost.swift` launches it. That file is meant to be deleted, and
`docs/MACOS-PORT.md` explains when and why.

**The lasting one:** two tests here read the backend's source to check this client against it.
A wire name that differs by an underscore compiles cleanly in Swift and then decodes to nil,
which on a caption means a line with no speaker and no clarity. Neither language can see the
other, so the check has to live above both, and the submodule is what puts them in one tree
long enough to compare.

The submodule pins a commit rather than tracking a branch, deliberately. A green test means
this client agrees with the backend **at that commit**, not with whatever is on its main
branch, and the test prints which commit so a passing run cannot be misread. Bumping the pin is
a reviewable act:

```bash
cd external/sunno && git fetch && git checkout <commit> && cd ../..
git add external/sunno && git commit
```

## What is already checked

Both run on a bare Python with no venv and no Xcode. They read text.

```bash
python tests/test_swift_protocol.py
python tests/test_theme_parity.py
```

`test_swift_protocol.py` imports the schema from the backend repository through the submodule
and checks `Protocol/Events.swift` against it in both directions: every event the backend can
emit has a Swift case, every Swift case names a real event, every wire field is one the backend
sends, and the `unknown` fallback exists so a newer backend cannot break an older client.
Sixteen event types, forty-one wire fields, plus the device list.

**It does not carry its own copy of the schema, and it must not grow one.** Two declarations of
one contract drift, and drifting silently is the exact failure being guarded against.

`test_theme_parity.py` compares `Theme.swift` against the Windows `App.xaml` through the same
submodule: two ink brushes, eight speaker hues, three clarity colours, and the seven numeric
rules that live in both codebases. A wrong digit in a speaker hue does not crash anything, it
makes two people in a four-way conversation closer in colour on the one screen whose job is
telling them apart.

Both were checked by deliberately breaking them, because a test that cannot fail is worth
nothing.

## Running it

The Mac needs the backend working first:

```bash
cd external/sunno
python3 -m venv .venv
.venv/bin/python -m pip install faster-whisper sounddevice soxr numpy websockets \
                                onnxruntime huggingface_hub sherpa-onnx
```

Deliberately not `pip install -r requirements.txt`. That file fails to resolve on macOS:
`pyaudiowpatch` publishes no macOS wheel and no sdist, and `nvidia-cublas-cu12` and
`nvidia-cudnn-cu12` publish only manylinux and win_amd64 wheels. The list above is the subset
that resolves.

`BackendHost` finds the backend at `external/sunno`, or as a sibling clone at `../sunno` if you
checked the two out separately.

### If the microphone prompt never appears

A plain command-line process with no `.app` bundle around it may be unable to present a TCC
dialog on macOS 26, and the symptom looks like a broken audio device rather than a missing
prompt. Run through Xcode rather than invoking the Python directly when testing capture.

## Layout

```
Sunno/
  SunnoApp.swift          entry point, menu bar commands, diagnostics allow-list
  Theme.swift             palette and numeric rules, mirrored from the Windows app
  Protocol/
    Events.swift          wire types, pinned by tests/test_swift_protocol.py
  Services/
    CaptionClient.swift   the socket, with an indefinite reconnect ladder
    BackendHost.swift     launches the Python engine. Temporary, see above
    DeviceCatalog.swift   device list, fetched from the backend's HTTP endpoint
    AppSettings.swift     preferences and the two window geometries
  Models/
    TranscriptStore.swift lines, speakers, status, assembled from the event stream
  Views/
    MainView.swift        window body, compact body, problem banner, empty state
    SidebarView.swift     speakers and the model disclosure
    TranscriptView.swift  the caption list
    CaptionTextView.swift AppKit text, for per-word confidence on hover
    CommandBar.swift      level meter, device picker, transport, status
    SettingsWindow.swift  Command comma, tabbed
    FirstRunView.swift    model picker
    SpeakerEditor.swift   rename, mark as self, merge
  Windowing/
    WindowChrome.swift    window level, minimum size, the two saved frames
docs/
  MACOS-PORT.md           the decisions, the evidence, what is unverified
  macos-mockup.html       the approved interface, screen by screen
external/sunno            the backend, as a pinned submodule
```

## Decisions worth knowing before changing things

**The transcript is AppKit, not SwiftUI.** `CaptionTextView` wraps an `NSTextView` because
hovering a word to see how confident the model was needs hit-testing that SwiftUI's `Text`
cannot do. The styling alone would work in SwiftUI; the hover would not.

**Uncertain words carry three signals, not one.** Grey, italic and an underline. Colour alone
would fail Differentiate Without Color, and this is the last app that should lean on hue.

**Settings is a separate window.** The Windows build uses a full-window page with a back arrow.
Command comma has to open something on macOS, and keeping the page would be the most obviously
non-native thing in the app. This is the one deliberate departure from the Windows shape; the
rest is identical.

**Compact mode lowers the window minimum before shrinking, and raises it after expanding.** In
the other order the window silently refuses the resize, because it is still holding a minimum
larger than the size being requested.

**`speaker_merged` and `speaker_deleted` are handled before the roster that follows them.** The
backend guarantees that ordering deliberately. Handle them the other way round and captions keep
the name of somebody the user just asked the app to forget.

**Device names never reach a log or the diagnostics export.** A capture device called "Headset
(R-Phonak hearing aid)" tells the reader the user wears a hearing aid, which is health
information arriving through a field nobody thinks of as sensitive. The report says whether a
device was chosen, never which.

**There is no AccentColor asset, on purpose.** Without one, `Color.accentColor` follows the
system accent the user chose, which is what the Windows build does. The brand teal lives in
`Theme.ink` and is used only for the mark and the badges.

## Not built yet

System audio capture. `docs/MACOS-PORT.md` recommends building the seam with ScreenCaptureKit
as the path that must work and the Core Audio tap as an enhancement on macOS 14.4 and later,
and that is phase 2. The owner routes system audio and a hearing aid through this path daily,
so it is the feature that decides whether the port is usable rather than merely working.

## Licence

MIT, matching the parent project. See [desigrit/sunno](https://github.com/desigrit/sunno) for
third-party notices, which cover the speech models and include one known licence gap.
