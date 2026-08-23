# Sunno on macOS: engineering notes

A decision document for Apple Silicon. Nothing here has been built and nothing here has been
measured yet, but two machines are now available, so most of what follows is a plan for
measuring rather than a plan for guessing. Claims that still rest on documentation or on
somebody else's report are marked as such, and the section near the end lists them with the
test and the machine that would settle each one.

Read `docs/ARM-PORT.md` first. The Windows on ARM port asked a version of the same question and
reached a different answer, and knowing why is most of the way to understanding this one. Note
also that it is not finished: six items are still open in its "What is left", including an engine
that has never been run. This document proposes a third platform while the second is incomplete,
which is a claim on the same person's time and is priced below rather than assumed away.

---

## The goal

A native macOS build for Apple Silicon: the same product, the same promises, a different engine
and a different capture path underneath.

The promises are the constraint, not the features. The README says the app works with the Wi-Fi
switched off and `PRIVACY.md` says there is exactly one network operation in the whole
application. A port that keeps the captions and breaks either of those has not shipped Sunno, it
has shipped something that resembles it.

## Recommendations

| Question | Recommendation | What would change it |
|---|---|---|
| Does the Python backend survive? | No, but the case is now about what the rewrite buys rather than whether it is allowed | A phase 0 measurement showing CPU-only CTranslate2 clearing `small` on the M1 Pro. That does not cancel the rewrite, it reprices it |
| What runs the model? | **WhisperKit for the rich tier.** It exposes `avgLogprob` and per-word probability as first-class Swift properties, so the clarity formula and the 0.55 word threshold transfer unchanged. sherpa-onnx for speaker embeddings, Silero unchanged | A side-by-side showing WhisperKit's probability distribution differs from faster-whisper's. Measure before trusting the formula |
| Minimum macOS? | **14.4.** It excludes no Apple Silicon hardware, and it is the single floor at which both WhisperKit and the Core Audio tap are available | Nothing found so far argues for going lower |
| Two model tiers, or one? | **Two tiers**, but for size and power rather than for confidence. This is about kinds of engine, not about how many models the picker offers, which grows | A Kyutai STT 1b measurement showing one kind of engine serves both tiers inside the battery budget |
| System audio? | Build the seam, ship ScreenCaptureKit as the path that must work, add the Core Audio tap on 14.4 and above if it proves out | A DTS answer on whether the tap works in the App Sandbox, or a failed stereo capture through the hearing aid route on macOS 26 |
| Distribution? | Decide after phase 2, not now. Dropping Python keeps both doors open | Whether the tap is needed, and whether it is sandbox-legal |
| Target hardware | Design for M1 Pro, support base M1 through the model picker that already exists | Nothing. See the next section, the question is malformed as a single floor |
| UI framework? | SwiftUI inside an `NSWindow` the app controls | Nothing |
| Permissions? | Microphone and system audio, explained by the app before the system asks | Nothing |
| Model storage? | `~/Library/Application Support/Sunno`, excluded from backup. Catalogue protocol unchanged, latency tables discarded | Nothing |

---

## Target hardware, and why there is no single floor

Available for measurement: a 14-inch MacBook Pro (A2442, M1 Pro or M1 Max) and a Mac Mini M4 Pro.
Both are Pro tier. Neither is the floor.

The proposal on the table was to set the base at M1 Pro, on the reasoning that it covers most Macs
in current use. The evidence runs the other way. The M1 MacBook Air was sold new from November
2020 until March 2024, the longest run of any Apple Silicon Mac, with retailer inventory into late
2024. The Air has historically been 60 to 70 percent of MacBook sales and analyst estimates put
entry-level Apple Silicon ahead of Pro and Max tiers by somewhere between two and three to one.
Apple publishes no install base breakdown, so treat the ratio as an estimate rather than a figure,
but the direction is not in doubt: **an M1 Pro floor would exclude the most numerous Apple Silicon
Mac there is**, and it is exactly the machine an accessibility tool should not exclude, because it
is the cheap one.

The better answer is that the question is malformed. Sunno already solves this per machine and has
for a while. `hardware.py` measures the processor, `default_model` picks a model the machine can
keep up with, and the picker quotes an estimated delay for every model before anyone spends
gigabytes finding out. That machinery exists precisely so there is no single hardware floor to
choose. A base M1 gets a smaller tier automatically, the same way a laptop without an NVIDIA card
does on Windows today.

So the useful split is three roles rather than one line:

| Role | Machine | What it is for |
|---|---|---|
| Design target | M1 Pro, on battery | The machine the defaults are tuned for, and the number that decides the shipped tier |
| Ceiling and newest OS | Mac Mini M4 Pro | Validates published benchmarks, and holds the newer macOS for the version-gated unknowns |
| Floor | Base M1, not currently available | Decides whether the picker tells the truth on the most common Mac |

**The risk on a base M1 is not that captions fail. It is that the picker lies.** Its entire job is
to say what each model costs on this machine, and `hardware.py` scales its tables by a measured
`cpu_score` that has never seen Apple Silicon. If the tables are derived only from Pro tier
hardware, the estimate a base M1 user reads before committing to a 3 GB download is wrong in the
optimistic direction, and they find out afterwards. That is a correctness bug in a feature that
already ships, not a support-matrix question.

There is a second gap neither machine covers. The M1 Air is fanless, and live captioning is
sustained load for the length of a conversation. A ninety minute meeting on a fanless machine is a
thermal scenario a Mac Mini cannot reproduce and a 14-inch MacBook Pro with fans only approximates.
`ARM-PORT.md` already learned this lesson in a different accent: power mode was worth about 1.6x
there, and the recorded conclusion was to design for a mid-range machine on battery rather than a
fast one plugged in. The same discipline applies. Measure the ceiling on the Mini, decide the tier
on the MacBook on battery.

Recommendation: proceed now with M1 Pro as the design target and extrapolate the floor from the
two-machine slope, then buy a used M1 Air before shipping. It is a few hundred dollars against an
app whose entire promise is keeping up, and the alternative is either an extrapolation nobody
checked or a README that excludes the most popular Mac.

---

## 1. The Python backend, and what replacing it actually buys

**Recommendation: rewrite the engine in Swift. Keep Python as the reference implementation and as
phase 0.**

The argument that matters is accuracy, arrived at through speed.

CTranslate2 is in a different position here than on Windows on ARM, and the difference is easy to
misread as good news. There, no wheel existed and the backend could not start. On macOS the wheel
exists: `ctranslate2` 4.8.1 publishes `macosx_11_0_arm64` wheels for seven Python versions and
`faster-whisper` is pure Python, so the engine installs and runs. It runs on the processor only.
PR [#2077](https://github.com/OpenNMT/CTranslate2/pull/2077), "Add native Apple Metal/MPS backend",
was opened on 21 July 2026 and was still open and unmerged on 18 August 2026. The earlier request,
issue #1819, is closed. There is no Neural Engine backend and none proposed.

So the question is what a processor-only Whisper can do, and `hardware.py:124-141` answers it for a
fast desktop x86 part: `large-v3` at 4540 ms on four threads and 4400 on sixteen, `medium` at 3460
and 2260, `small` at 1450 and 810, `base` at 730 and 405. Against a 1000 ms responsiveness budget
that is a tier of `base`, with `small` marginal. Which is exactly where `ARM-PORT.md` landed, for
the same reason, and it recorded the cost honestly: "latency beats accuracy on ARM".

That cost is larger here than it looks, because it is the thing the app was built to avoid.
`ENGINEERING.md` spends its longest section explaining why Whisper large-v3 rather than anything
faster, and the answer is accented speech: 7.2% WER on SVARAH against 20.7% for a commercial
`en-IN` model, and a measured warning that pruned decoders degrade two to four times worse on
harder audio than on clean. Sunno exists because its author misses words. Shipping the Snapdragon
tier to a machine with a capable GPU and a Neural Engine sitting idle would trade away the model
choice that is the app's whole thesis, in order to keep a backend.

It is a performance argument only in the sense that the performance buys the model, and the model
is the product.

**The gate is a price, not a veto.** An earlier draft said that if CPU-only CTranslate2 cleared
`small` inside the budget you should stop and keep Python. With a free hand to rebuild, that is
too strong. The measurement does not decide whether to rewrite, it decides what the rewrite is
worth: if CPU already manages `small` at 800 ms, the rewrite buys `medium` or `large-v3-turbo`
instead, which is real accented-speech accuracy. If CPU manages only `base`, it buys considerably
more. Either way it is a judgement with a number attached rather than a yes or no, and the number
is an afternoon away.

**The distribution argument is not load-bearing, and it points the other way.** An earlier draft
led with it. It runs: `app/Package.appxmanifest:43-48` ships Sunno as a
`Windows.FullTrustApplication` and `:66` declares `runFullTrust`, to stay out of AppContainer so
the backend can load native DLLs and use a localhost socket. The Mac App Store has no equivalent,
because the [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) is
mandatory there, and inside it an embedded CPython needs
[`com.apple.security.cs.disable-library-validation`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
to `dlopen` its C extensions, which notarisation permits and App Review is widely reported to
refuse.

All true, and all conditional on wanting the App Store. Recommend Developer ID and the sandbox
never applies. The useful implication is the inverse of how it was written: **deleting Python is
what makes the App Store possible again.** A Swift engine linking a static whisper.cpp XCFramework,
or Core ML through WhisperKit, has no unsigned `.so` files to `dlopen` and needs no
library-validation exception. The rewrite is not what forces Developer ID, it is what keeps both
doors open, which is why distribution is deferred to phase 2.

**The cheap alternative, recorded and rejected: keep Python, ship Developer ID, add a small Swift
capture helper.** It preserves `pipeline.py`'s two-pass discipline, `speaker.py`'s tuned online
matching, `preprocess.py`, every constant in `config.py` and every existing test, and the Swift
surface is nearly the same either way because the capture helper is needed regardless. It is
rejected because it holds macOS at the `base` tier for as long as CTranslate2 has no Metal backend
and forecloses the App Store for as long as the payload needs a library-validation exception, so
it is the only option that gives up both the model and the store at once. Neither is strictly
permanent, since PR #2077 exists, but neither has a date.

**What is genuinely reusable.** "Rewrite in Swift" sounds like discarding the backend and it is
not. Reusable as running code, unchanged:

| What | Why it survives |
|---|---|
| `ui/` (`index.html`, `app.js`, `style.css`) | The phone route is a web page over HTTP and a WebSocket. It does not care what serves it |
| The event protocol | `status`, `partial`, `final`, `roster`, `level`, `download_progress`, `model_catalog`, defined across `app.py:290-357` and consumed by `ui/app.js` and `CaptionClient.cs` |
| The model catalogue shape | `models.py:57-116`. The backend sends a catalogue and the UI renders it, which is why the WinUI app knows no model ids and a Swift one would not need to either |
| Silero VAD weights | `server/assets/silero_vad_v6.onnx`, already vendored by the ARM work |
| The speaker embedding model | `speaker-embedding-campplus-en.onnx`, 28 MB, already in the package |

Reusable as design, which is to say a Swift author reads the Python and writes the equivalent:

| What | Where | Note |
|---|---|---|
| Endpointing state machine | `pipeline.py:286-341` | Start debounce, pre-roll, end silence, forced commit on long monologues. Sixty lines carrying a lot of tuning |
| Two-pass worker discipline | `pipeline.py:81-195` | Single-slot partial queue so a newer snapshot supersedes a stale one, finals take priority and cancel their own partial. This is what keeps captions close to live and it is not obvious |
| Audio conditioning | `preprocess.py` | 75 lines: DC removal, an 80 Hz Butterworth biquad, capped level normalisation. Ports to Accelerate almost mechanically, and `tests/test_biquad.py` already exists to prove the port |
| Tunables | `config.py` | Every number was chosen for a reason recorded beside it. Copy the file as constants, not the values as guesses |
| Hallucination suppression | `config.py:104-121`, `asr.py:181-187` | The phrase list and `drop_no_speech_above`, which exists because faster-whisper's own threshold only fires when the log-prob check also fails |
| Online speaker matching | `speaker.py` | Centroids, pinning, the `min_identify_s` and `min_new_speaker_s` guards. The measured similarity table in its docstring is why those guards exist |

Not reusable at all: `loopback.py`, `cuda_setup.py`, the WASAPI narrowing in `audio.py:30-77`, the
`IsWow64Process2` pair in `hardware.py:159-210`, and every latency number in `hardware.py:70-141`,
which describes neither the chip nor the engine this port would use.

---

## 2. The engine: WhisperKit for the rich tier

The deciding feature is not speed. Sunno shows a clarity score on your own lines and shades
uncertain words, and both come from decoder internals. `asr.py:97-106` derives clarity from
Whisper's average token log-probability and `asr.py:199-205` takes per-word probabilities from
`word_timestamps=True`. `asr_stream.py:89-97` returns `clarity=None` and no words, and three
surfaces say "Whisper models only" because of it, pinned by `tests/test_stream_engine.py:381-385`.
Any engine that cannot expose per-token probabilities silently deletes two features, and `4071d0a`
shows how much work went into making the app honest about exactly that.

That requirement removes the most tempting option. Apple's `SpeechAnalyzer` and `SpeechTranscriber`
are fully on-device, stream natively and need no model shipped with the app, but they expose no
per-token probability distribution and they require macOS 26. Recorded as a rejected alternative
rather than a future one, because the missing score is structural rather than a gap someone will
fill.

**Recommendation: WhisperKit.** An earlier draft called it and whisper.cpp co-equal and asked for a
bench. Two findings settle it without one.

WhisperKit exposes `TranscriptionSegment.avgLogprob` and `TranscriptionSegment.words[i].probability`
as first-class Swift properties, produced by the same alignment mechanism faster-whisper uses. That
means **the clarity formula and the 0.55 word threshold transfer unchanged**, which removes the
largest single item of work the parity matrix carried: an earlier draft had both constants needing
re-derivation from measurement before the features could ship. They still need verifying against
the existing test audio, because "same mechanism" is an argument rather than a measurement, but the
expected answer is now "no change" rather than "recalibrate".

whisper.cpp reaches the same data at the C level through `whisper_full_get_token_data()`, but only
as raw token structs. Assembling `avgLogprob` and word-level probabilities out of those is work the
app would own and would have to keep matching against faster-whisper's definitions, which is exactly
the sort of quietly-drifting duplication `4071d0a` is a lesson about. It stays as the fallback if
WhisperKit disappoints, and its static XCFramework at `MACOS_MIN_OS_VERSION=13.3` remains the reason
the App Store door stays open on either path.

**This sets the floor at macOS 14**, since that is WhisperKit's minimum. That is not the constraint
it first appears to be. Every Apple Silicon Mac ever made runs macOS 14, so it excludes no hardware,
only people who have not updated. And the Core Audio tap needs 14.4 regardless, so **14.4 is the one
floor at which the recommended engine and the honest audio permission are both available**. Two
constraints that looked independent turn out to agree.

Its real costs remain and should be recorded rather than forgotten: the weights are one vendor's
Core ML conversions rather than the upstream ggml files, which is the same supply-chain concern
`THIRD-PARTY-NOTICES.md` already documents for Kroko, and it needs the same treatment before ship.

**Speaker labelling survives intact, which was an open question.** The sherpa-onnx C API does expose
speaker embedding extraction, through `SherpaOnnxCreateSpeakerEmbeddingExtractor`, and it produces
the same 512-dimensional CAM++ vector the existing profiles in `speakers.json` are built from. So
`speaker.py`'s centroid matching, pinning and merging port across without a model change and without
invalidating anyone's saved speakers. WhisperKit ships `SpeakerKit`, Pyannote diarisation on Core ML,
in the same package, but it does batch diarisation over a buffer where this app does online
per-utterance matching against named profiles, so it is not a drop-in and is not needed.

Both frameworks share one `AVAudioEngine` tap and each consume the same buffer, so this is two SPM
dependencies rather than two audio pipelines. Build sherpa-onnx with `-DBUILD_SHARED_LIBS=OFF` to
avoid shipping a dylib and the code-signing problem that comes with one.

**Silero stays where it is**, a two megabyte model on 32 ms frames already pinned to
`CPUExecutionProvider` at `vad.py:82`. Do not chase the CoreML execution provider for it: the
dispatch overhead exceeds anything it could save.

**Do not inherit the ARM tier by reflex.** If Metal and the Neural Engine deliver, the
accent-robustness argument points back up the model list rather than down it. Measure, then choose.

---

## 2a. The catalogue: it grows, and it keeps two kinds of engine

**To be unambiguous, because an earlier draft was not: the picker keeps offering many models, and on
macOS it should offer more than Windows does, not fewer.** `models.py:57-116` currently puts seven in
front of the user (large-v3, distil-large-v3, medium, small, base, Zipformer, Kroko) while `--model`
accepts nineteen ids besides. None of that changes. What follows is about which *kind* of engine each
entry is, because the app already treats the two kinds differently and the UI says so in three places.

The two kinds are Whisper checkpoints, which carry a clarity score and per-word probabilities, and
streaming transducers, which return `clarity=None` and no words. That split is deliberate. The
question worth asking on a new platform is whether it is still right and whether the occupants have
changed.

**The split is still right, but the reason has moved.** It is no longer mainly about confidence,
which the lean tier is allowed to omit. It is about size and power. A 26 to 69 MB transducer on a
fanless M1 Air over a ninety minute meeting is a different power envelope from a 1.5 GB accuracy
model, and no model that reaches the rich tier's accuracy on accented English currently fits the
lean tier's size budget. Keeping two kinds of engine remains the right architecture for at least
this cycle.

The one candidate that could collapse the two kinds into one is **Kyutai STT 1b**, which is
architecturally the best match to what this app actually needs: a committed prefix rather than a full
re-decode, semantic VAD, and its own punctuation and casing. At INT4 in MLX it is roughly 500 MB,
which is too large for the lean tier as the yardstick currently stands but small enough to be worth
measuring. The test is specific: load it on the M1 Pro on battery, run a ninety minute conversation,
and record peak memory, average power and first-committed-word latency. Even if it succeeds, that
simplifies the engine code rather than the picker.

### The catalogue as proposed

Nine entries against the current seven. Ordered best-accuracy-first, as `CATALOG` already is, because
`hardware.default_model` scans it in order.

| # | Model | Kind | Status | Note |
|---|---|---|---|---|
| 1 | Whisper large-v3 | rich | Keep, default | The only calibrated confidence signal and the only published accented-English benchmark. Stays the reference |
| 2 | Whisper large-v3-turbo | rich | **Add** | Same tokenizer, so the clarity formula applies unchanged. Test on SVARAH before describing it as accuracy-equivalent. Windows omits it because CTranslate2 made it a poor trade; the Neural Engine may change that |
| 3 | Distil-Whisper large-v3 | rich | Keep | Half the size, English only |
| 4 | Whisper medium | rich | Keep | |
| 5 | Whisper small | rich | Keep | |
| 6 | Whisper base | rich | Keep | The floor for a slow machine |
| 7 | Zipformer (`stream-en`) | lean | Keep | Apache-2.0, the honest fallback |
| 8 | Kroko (`stream-en-kroko`) | lean | Keep, still never auto-selected | Writes its own capitals and punctuation, which is most of why it is worth having. Licence position unchanged and stays documented |
| 9 | Moonshine v2 Tiny | lean | **Add** | MIT, 26 to 34 MB, commits a prefix rather than re-deciding, and takes variable-length input rather than padding to thirty seconds, which is the structural reason short conversational turns are expensive on Whisper |

### Candidates not yet in the list, and what blocks each

| Model | Kind | Blocker |
|---|---|---|
| Kyutai STT 1b | either, possibly both | Confirm confidence is reachable from MLX, get an accented benchmark, measure the battery budget |
| Parakeet TDT 0.6b | rich | Its confidence is a transducer score rather than an average log-probability, so the clarity mapping needs re-deriving before it can join the rich tier |
| Parakeet EOU 120M | lean | Evaluate against Moonshine. Apache-2.0, runs on the Neural Engine through FluidAudio, pure Swift with no dylib |
| CrisperWhisper 2.0 | rich | CC-BY-NC on the fine-tuned weights. The most interesting model here for this particular user, because it transcribes verbatim and handles disfluency, so it reports what was actually said rather than a tidied version. Worth asking Nyra Health |
| Granite Speech 4.1, Qwen3-ASR | rich | Best open scores available and Apache-2.0, but no ONNX or Core ML export path and no accented numbers. Next cycle |
| WeNet U2++ | lean | No clear advantage over Zipformer for English today |
| Canary-Qwen, MMS, wav2vec2, Vosk | neither | Over budget, or measurably worse on accented speech, which is the one axis this app cannot trade |

Nothing in the wire protocol or the macOS client constrains this list. The backend sends a catalogue
and the UI renders whatever arrives, which is why `app/` knows no model ids and this client does not either. Adding a tenth model is an edit to `models.py` and nothing else.

### Two findings worth acting on separately

**A one-string experiment comes before any model change.** `asr_stream.py:65` pins the recogniser to
`provider="cpu"`. On Apple Silicon that leaves the Neural Engine idle for the lean tier. Changing it
to `provider="coreml"` and re-running `bench/bench_stream_latency.py` costs one line and could
resolve the lean tier's Apple Silicon story without touching a model. Do this first.

**The lean tier's real defect is not the model, it is the pipeline.** `asr_stream.py:15-26` explains
that each partial rebuilds a fresh stream over the whole utterance, and `:121-130` measures what that
costs: `stream-en` revised text already on screen on 147 of 251 refreshes, Kroko on 44. Swapping in a
committed-prefix model does not fix that on its own, because the pipeline still hands the engine the
whole utterance every time. The fix is the seam change the file's own comment describes, handing out
deltas with a committed prefix, and it is worth more than any model swap in this tier.

### One idea that is not in the current product

`SenseVoice-Small` tags audio events, laughter, applause, a door, an alarm, in the same pass that
produces the transcript. For someone who cannot hear well, knowing that the room laughed is
sometimes the information they missed, and no other model in this survey does it. It is not a
replacement for anything and its model licence is separate from its MIT code, so it would need the
same treatment `THIRD-PARTY-NOTICES.md` gives Kroko. Recorded as a product idea rather than a
recommendation, because it changes what the app is for rather than how it works.

---

## 3. System audio is the highest risk item

There is no WASAPI loopback on macOS. `loopback.py` is Windows in full and `pyaudiowpatch` publishes
no macOS wheel and no sdist, so nothing in that file survives. This matters more than a feature list
suggests: the owner routes system audio and a Phonak hearing aid through this path daily, and
`audio.py:66-75` shows the codebase already treats a capture device name as health information.

| | ScreenCaptureKit `SCStream` | Core Audio process tap | Virtual device (BlackHole) |
|---|---|---|---|
| Minimum macOS | 12.3, practically 13.0 | **14.4** | 10.10 |
| What the user is asked | "would like to record this computer's screen" | An audio capture prompt, from `NSAudioCaptureUsageDescription` | Nothing, but an admin password to install |
| TCC bucket | Screen and System Audio Recording | System Audio Recording Only | None |
| Sandbox entitlement | None. TCC only | None published | Cannot install from a sandbox |
| Works in the App Store sandbox | Yes, and a shipping app has been identified | **Unknown, probably not** | No |
| Audio only | No. A `.screen` output must be added and its frames discarded | Yes | Yes |
| Capture one app | Yes | Yes | No |
| Recording indicator | Purple dot | Purple dot | None |
| Pre-flight permission check | No | No | N/A |
| Setup burden | A dialog | A dialog | Install, then build a Multi-Output Device by hand |

On the entitlement row, `com.apple.security.screen-recording` **does not exist**. Apple's entitlement
documentation returns 404 for it while
[`device.audio-input`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input),
[`device.microphone`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone)
and
[`cs.disable-library-validation`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
all resolve. Screen recording is governed purely by TCC plus an `NSScreenCaptureUsageDescription`
string. Two research passes disagreed on this and both initially got it wrong.

On the indicator row, an earlier draft argued ScreenCaptureKit was worse for putting a purple dot in
the menu bar. It is not: from macOS 15 onward both paths show one and only the Control Center label
differs. That is the right outcome rather than a cost, because an indicator the app cannot suppress
tells a room that capture is running more credibly than the app could.

**Rule out the virtual device.** BlackHole is MIT and technically fine, but it works by becoming the
system output, so hearing the audio at the same time requires building a Multi-Output Device in Audio
MIDI Setup. Get that wrong and sound stops reaching the hearing aid. Asking a hard of hearing user to
hand-configure the audio route their hearing depends on, where the failure mode is silence, is not a
trade this app should offer.

**Recommendation: build the seam, make ScreenCaptureKit the path that must work, add the Core Audio
tap as an enhancement on macOS 14.4 and above.**

An earlier draft recommended the tap alone, on the grounds that asking permission to "record this
computer's screen" in order to caption a video call is the wrong noun and broader than the need. That
argument is real but it is an argument about a sentence, and section 6 states the principle that
defuses it: the app explains each permission before the system does. One sentence of pre-explanation
costs less than everything the tap-only path costs, which is the App Store, two macOS versions of
reach, an API whose sandbox status nobody outside Apple can confirm, and a known trap where a
tap-only aggregate device leaves the IOProc silently never firing.

The tap is still worth having, for two reasons about this user rather than about elegance. Its prompt
is honest. And there is a community report that ScreenCaptureKit on macOS 26 sums system audio to
mono or drops a channel when an external audio interface is in use, which lands squarely on the
hearing aid route and would be a silent quality regression on the path that matters most. That report
is unconfirmed and is in the verification table. If it holds, the tap stops being a nicety.

So build both behind one protocol. `LoopbackStream` and `MicrophoneStream` already present an
identical contract to the pipeline, and `loopback.py:120-126` says so out loud. That seam is what
makes it cheap to ship one, discover it is blocked or degraded, and fall back without touching
anything above it.

**Two machines make the version-gated unknowns testable, which is the main reason to keep them on
different macOS releases.** Most of what could not be verified here is a question about macOS 15
against macOS 26 rather than about hardware: the mono regression, whether the tap shows an indicator,
whether the audio-capture TCC bucket is still separate, whether a plain CLI process can raise a TCC
prompt at all. Keep the Mini on the newer release and the MacBook one behind, deliberately, rather
than letting both drift forward together. Once both are on 26 that A/B is gone and the only way back
is a reinstall.

**On implementation, and one dependency to refuse.** `catap` is the obvious shortcut, a Python binding
for the tap API with CI, releases and macOS 26 testing. It also has zero stars, zero forks and a single
author, and it was first published four months ago. The objection is not the author's competence, it is
that a dependency in the audio path of an accessibility tool has to be one somebody can fix at three in
the morning. Writing a thin Swift helper is not the same bet despite also being new, because the failure
mode differs: unfamiliar code you own can be debugged, and an unfamiliar dependency you do not own has to
be waited on. Use [AudioCap](https://github.com/insidegui/AudioCap) as the reference, BSD 2-Clause and
508 stars, by a known macOS developer, and note its licence would permit vendoring outright if writing
from scratch proves slower than expected. `audiotee`, the other obvious sample, ships **no licence
file**, so read it and do not copy from it.

**Settle the sandbox question in parallel.** Whether `AudioHardwareCreateProcessTap` works inside the
App Sandbox is binary, no public source answers it, and Apple can. File a DTS incident. If the answer
is yes, the App Store and the honest prompt stop being mutually exclusive.

---

## What a free hand opens

Rebuilding from scratch removes a constraint that was shaping several answers silently. These are
decisions rather than consequences, and they are worth taking deliberately.

**Product shape.** A from-scratch Mac app does not have to be a window with a compact mode. Compact
mode (`MainWindow.xaml.cs:3018-3085`) is already an approximation of a floating caption strip, and the
idiomatic macOS form is a menu bar extra plus a floating panel. This is the decision to take before any
code, because it shapes the UI layer entirely and it is the one thing on this list that is expensive to
reverse.

**Does the phone and browser route survive?** On Windows it is nearly free, because the backend is
already an HTTP server. An in-process Swift engine has no server, so `ui/` becomes net-new work rather
than a side effect. If it is unused, dropping it removes the network entitlements and the firewall
prompt entirely and simplifies the sandbox story.

**How much parity does v1 need?** A free hand is also freedom to ship something narrower and sharper
first, rather than tracking the Windows feature list.

**One codebase or two, permanently.** If Swift wins on Mac, does Windows eventually follow, or are two
engines carried indefinitely? The position here is to share only the protocol, the catalogue and the
user-facing strings and accept two engines. `4071d0a` is the argument for sharing the strings: a promise
about clarity scores drifted out of step across the picker, a settings toggle, two dialogs and the
browser client, and a second platform doubles the places that can drift.

---

## The remaining questions

### 4. UI framework: SwiftUI, with AppKit underneath

SwiftUI mostly justifies itself: VoiceOver, Reduce Motion, Increase Contrast and Dark Mode come largely
for free, and none of those is garnish on this app. It does not do the window. Compact mode collapses
the sidebar and command bar, forces always-on-top for as long as it lasts, swaps the minimum window
size, and remembers geometry separately per mode (`AppSettings.cs:64,77-80`). That is `NSWindow.level`,
`contentMinSize` and frame autosave, so expect an `NSHostingView` inside an `NSWindow` the app controls
rather than a bare `WindowGroup`. No XAML ports; a shared design language with WinUI buys nothing.

### 5. Distribution: decide after phase 2

Notarisation requires a Developer ID Application certificate, the Hardened Runtime on every Mach-O, a
secure timestamp and no `get-task-allow`. It does **not** require the App Sandbox, which is mandatory
only for the App Store. Dropping Python means that fork does not have to be taken yet.

- **Spawning a child process.** Fine unsandboxed. Sandboxed it is prescribed: the helper lives in the
  bundle, carries exactly `com.apple.security.app-sandbox` and `com.apple.security.inherit` and nothing
  else, and is signed with the same Team ID. Extra entitlements make it crash at launch with a signing
  error. This applies even on the Swift path, because the audio helper is a child process.
- **Downloading models at runtime.** Not prohibited. Guideline 2.5.2 targets downloaded *code that
  changes features*, and weights are data consumed by an engine reviewed at submission.
- **Audio capture.** `com.apple.security.device.audio-input` for the microphone on a notarised build,
  `com.apple.security.device.microphone` for a sandboxed one, plus TCC either way.
- **The localhost socket.** Unsandboxed, nothing to declare. Sandboxed, `com.apple.security.network.server`
  to bind and `com.apple.security.network.client` to connect, because the sandbox does not exempt
  loopback, and the firewall may prompt regardless. Only needed at all if the phone route survives.

The costs of each door: the App Store buys discovery and automatic updates and costs the tap; Developer
ID keeps the tap and the honest prompt, costs discovery, and puts the update mechanism on the project.

### 6. Permissions, and making them legible

| Prompt | Info.plist key | When | Recoverable in app |
|---|---|---|---|
| Microphone | `NSMicrophoneUsageDescription` | First capture. `AVCaptureDevice.authorizationStatus(for:)` and `requestAccess(for:)` give the same check-then-ask split `MicrophoneAccess.cs` relies on today | Yes, until denied once |
| System audio, tap path | `NSAudioCaptureUsageDescription` | First tap. No pre-flight check found | No |
| Screen recording, ScreenCaptureKit path | `NSScreenCaptureUsageDescription` | First stream. Requires relaunch after granting | No |

Once denied none re-prompts, so the app has to notice and say where to go, in words, without blaming the
user. The Windows app gets this right and the reasoning is at the top of `Services/MicrophoneAccess.cs`:
treating "never asked" as a refusal is how you strand someone. Neither macOS system audio path offers the
equivalent of `AppCapability.CheckAccess()`, so that distinction has to be inferred from a failed capture,
which is a real regression and the one piece of that file's logic that does not port.

The usage description strings are the whole of what the user reads at the moment they decide, and for an
app whose users came to it because they cannot hear well they should say what is captured and what happens
to it, in one sentence, in the register of `PRIVACY.md`. On the ScreenCaptureKit path the app must also
say, in its own words and before the system asks, that it needs the screen recording permission because
that is where macOS keeps system audio, and that no screen content is read. That sentence is the entire
remedy for the wrong noun.

Pausing must genuinely release the tap and the device, the way `pipeline.py` already closes the microphone
on stop, because on macOS the indicator is the only honest signal the room gets.

### 7. Accessibility parity

| Setting | macOS mechanism | State |
|---|---|---|
| VoiceOver | SwiftUI `.accessibilityLabel` / `.accessibilityValue` / `.accessibilityHint` | Direct equivalent. The XAML carries 35 `AutomationProperties` uses, mapped by hand |
| Reduce Motion | `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` plus `accessibilityDisplayOptionsDidChangeNotification` | Direct equivalent of `UISettings().AnimationsEnabled` at `MainWindow.xaml.cs:1397` and `SunnoMark.xaml.cs:61-65` |
| Increase Contrast | `accessibilityDisplayShouldIncreaseContrast` | Better than today. The Windows app does not read the equivalent |
| Differentiate Without Color | `accessibilityDisplayShouldDifferentiateWithoutColor` | Already satisfied by construction: `WordInlines.cs:135-147` marks uncertain words grey **and** italic **and** underlined. Keep that |
| Text size | No Dynamic Type on macOS. macOS 14 has a Text Size slider but no documented change notification | The app's own A+ / A- and the persisted `CaptionFontSize` stay as the primary control |

Two decisions to carry over deliberately. Caption rendering follows BBC and DCMP live-subtitle convention:
provisional text dimmed and italic, replaced exactly once at the utterance boundary, corrections batched at
sentence boundaries rather than churning word by word. And own lines render fainter and labelled, which is
a reading-load decision as much as an attribution one.

### 8. Model storage and download

The catalogue and download protocol carry over in shape. The event protocol (`download_started`,
`download_progress`, `download_complete`, `download_failed`) and the first-run gate in `app.py:463-484`
need no change. The numbers beside each entry do: `approx_mb` is right, `hardware.py`'s lag tables are not.

What does not carry over cheaply is `huggingface_hub` itself. It handles resumable ranged fetch, etag
caching, a symlinked blob store and integrity, and `models.py` leans on all of it for a 3 GB download. On
the Swift path that is a component to write and test against a flaky connection, not a protocol to
translate.

Three path defects need a macOS branch:

- `paths.py:30-34` has a non-Windows branch returning `~/.sunno`, a Linux convention. macOS wants
  `~/Library/Application Support/Sunno`.
- `models.py:211-214` `_stream_root()` reads `LOCALAPPDATA` and falls back to the home directory, putting
  streaming models in a bare `~/Sunno/stream-models`.
- The Whisper weights land wherever `huggingface_hub` defaults to, which is `~/.cache/huggingface`.
  `PRIVACY.md` tells users the model is cached "in the Hugging Face cache directory under your user
  profile", and that sentence needs a macOS answer.

Recommended: everything under `~/Library/Application Support/Sunno/`, model directory marked
`isExcludedFromBackup`. Not `~/Library/Caches`, which the system may purge, and purging the model turns
"works with the Wi-Fi off" into a lie at the worst possible moment. A sandboxed build makes these
container-relative automatically, which also relocates `HOME`, so anything resolving a path through
`expanduser` moves with it silently.

---

## UX parity matrix

Two gap columns, because "no capability gap" and "no work" are different claims and collapsing them is how
a plan gets optimistic.

| Feature | macOS mechanism | Capability gap | Work |
|---|---|---|---|
| Live captions, provisional refined to final | Same pipeline design in Swift | None | Substantial. `pipeline.py:81-195` and `:286-341` by hand |
| Always on top, resizable | `NSWindow.level = .floating` | None | Small |
| Compact mode, geometry per mode | `NSWindow` frame autosave, two saved frames | None | Moderate, and see the product shape decision above |
| Speaker labels, rename, merge, delete | sherpa-onnx embeddings via C API, same protocol | None | Substantial, but the dependency risk is now closed: the C API exposes embedding extraction and the vector matches. `speaker.py`'s matching logic still ports by hand |
| "This is me", own lines dimmed | Same | None | Small |
| Clarity score | `TranscriptionSegment.avgLogprob` from WhisperKit | None | **Smaller than it was.** WhisperKit produces the same quantity faster-whisper does through the same mechanism, so `asr.py:105`'s mapping is expected to transfer unchanged. Verify against the existing test audio rather than assuming; a distribution shift would silently change what the number means |
| Per-word uncertainty shading | `TranscriptionSegment.words[i].probability` | None | Same. `config.py:126`'s 0.55 threshold is expected to hold, and the token-to-word grouping whisper.cpp would have required is done for us |
| Speaker labels, rename, merge, delete | `SherpaOnnxCreateSpeakerEmbeddingExtractor` via the C API, same 512-dim CAM++ model | None | **Resolved.** The C API does expose embedding extraction and the vector matches the existing profiles, so saved speakers stay valid. `speaker.py`'s matching logic still ports by hand |
| Streaming models have neither | Unchanged | None | None |
| Model picker with per-machine delay | Same protocol | None | **Every latency number remeasured, on at least two machines.** See the target hardware section: this is where a base M1 gap becomes a correctness bug |
| Download progress, first-run flow | Same protocol | None | Substantial on the Swift path. `huggingface_hub` is a component, not a protocol |
| Microphone capture | Core Audio or AVAudioEngine | The WASAPI "connected versus merely remembered" filter at `audio.py:30-77` has no direct equivalent | Moderate |
| System audio capture | ScreenCaptureKit, or a tap on 14.4+ | **Reach, or an unconfirmed macOS 26 channel regression.** Highest risk in this document | Substantial |
| Stop releases the device | Same, and it must tear down the tap or stream too | None | Small |
| Caption font size | App-controlled, as today | None. macOS has no Dynamic Type to defer to | Small |
| Force CPU | Becomes "force CPU over Metal and ANE" | Meaning changes, wording needs revisiting | Small |
| Diagnostics export | Same allow-list, rewritten | None | Moderate. Fields change, and the allow-list discipline must survive intact |
| Reduce animation respected | `accessibilityDisplayShouldReduceMotion` | None | Small |
| Fully offline after download | Same | None, provided nothing in the new stack phones home | Verification, not code. Check WhisperKit and any Core ML asset fetch against this |
| Browser client for phone | Unchanged, if kept | None | See the decision above. Net-new on an in-process engine |

---

## What this costs

**Money.** The measurement hardware is already owned, which removes the largest line item this document
previously carried. What remains is the Apple Developer Program at 99 USD a year, recurring, needed for
notarisation as much as for the Store, and a used base M1 Air before shipping if the floor is to be proved
rather than extrapolated.

**Time.** Phase 0 is a day. Phase 1 is a SwiftUI shell, an engine integration, a Silero path, a capture
layer and the endpointing and two-pass logic ported by hand. Phase 3 adds the speaker matcher, remeasured
tables, compact mode, settings and diagnostics. Phase 4 is signing, notarisation, a permission flow and a
VoiceOver audit. For one person this is quarters, not weeks, and nothing after phase 0 is a weekend.

**Attention.** The ARM port has six open items and an engine never run. The Windows app is at 1.0.76 and
used daily. Starting macOS means one of those gets less. Not an engineering question, and this document
does not answer it, but it should not be decided by accident.

**Doing nothing** costs nothing. Windows users keep a working app and Mac users get nothing. Nothing here
establishes that macOS users exist or how many, because no such evidence was available. If there is a "why
now", it is not technical and it belongs in the decision.

---

## What exists now

This repository holds the app, written but never compiled: there was no Mac to compile it on, so the first build
on the M1 Pro will find mistakes. 2,427 lines across 17 Swift files, matching the approved mockup screen
for screen. `README.md` is the build handoff, and `docs/macos-mockup.html` is the mockup itself,
which is worth opening in a browser before reading any of the Swift.

It talks to the existing Python backend over the existing WebSocket protocol, which is the deliberate
bridge described above. That means the UI can be finished and judged before the engine decision is taken,
and `Services/BackendHost.swift` is the file to delete when it is.

Three things were verified from Windows, because they are the mistakes a Swift compiler cannot catch and
that are most expensive to find on the Mac:

- `tests/test_swift_protocol.py` reads the backend's own source, extracts every event it can emit, and
  compares that against `Protocol/Events.swift` in both directions. 16 event types, 41 wire fields, 10
  commands and the 8-field device list. A wire name that differs by an underscore compiles cleanly in
  Swift and then silently decodes to nil, which on a caption means a line with no speaker and no clarity:
  the feature looks broken rather than misspelt.
- `tests/test_theme_parity.py` compares `Theme.swift` against `App.xaml`: two ink brushes, eight speaker
  hues, three clarity colours and the seven numeric rules that live in both codebases. A wrong digit in a
  speaker hue makes two people in a four-way conversation closer in colour on the one screen whose job is
  telling them apart.
- Both were checked by deliberately breaking them, because a test that cannot fail is worth nothing.

What is not verified is everything a compiler would catch. Treat the Swift as a careful first draft.

---

## Picking this up on another machine

The conversation that produced this document does not travel. Session history is stored per
machine, so opening the app on a different Mac or PC starts empty. That is deliberate on this
project rather than a problem to work around: the reasoning is supposed to live in the repository,
which is why this file records rejected alternatives and measurements rather than just conclusions.

Everything needed is in these two repositories. In order:

1. `external/sunno/docs/CONTEXT.md`, the project context and everything learned building the
   Windows app. Read this first if you have not worked on Sunno before, or if it has been a
   while. It carries the promises, the measurements, the decisions that were made twice, and
   the bugs worth knowing about. It lives in the backend repository because most of what it
   records is about the pipeline, which both platforms share.
2. `docs/MACOS-PORT.md`, this file. The decisions, the evidence, and what is still unverified.
3. `docs/macos-mockup.html`, the approved UI. Open it in a browser. Every screen, the macOS control
   mapping, and the three places a macOS pattern conflicts with the Windows shape.
4. `README.md`, the build handoff. How to generate the Xcode project and what will break first.
5. `Sunno/`, the app itself. Written, never compiled.

**The first four commands on the Mac:**

```bash
git clone --recurse-submodules https://github.com/desigrit/sunno-macos.git && cd sunno-macos
python tests/test_swift_protocol.py     # should pass, needs no venv
python tests/test_theme_parity.py       # should pass, needs no venv
brew install xcodegen && xcodegen generate && open Sunno.xcodeproj
```

The two tests passing on arrival confirms the submodule resolved and that the Swift wire types
still agree with the Python backend at the pinned commit. The Xcode build is where the uncompiled
code meets a compiler for the first time, and it will find things.

**Then phase 0**, below, which is a day of measurement and is what everything else waits on.

---

## Phased plan

The gate is explicit: **phase 1 does not start until phase 0 has measured a decode time on the MacBook, on
battery.**

**Phase 0, a day, and the point is to falsify this document cheaply.**

Start with the engine bench, because it produces the number everything turns on without writing an app.
Run `whisperkit-cli` across `base`, `small`, `medium`, `large-v3-turbo` and `large-v3`, then the same set
through whisper.cpp as the control. Do it on both machines.

Alongside it, the one-line experiment that is cheaper than everything else here: change
`asr_stream.py:65` from `provider="cpu"` to `provider="coreml"` and re-run
`bench/bench_stream_latency.py`. That is the lean tier's whole Apple Silicon story tested for the cost of
one string, and it should happen before any model is swapped.

Then the Python baseline. Do not run `pip install -r requirements.txt`: it fails at resolution on macOS,
and the reason is in the file. `pyaudiowpatch` publishes no macOS wheel and no sdist, and
`nvidia-cublas-cu12` and `nvidia-cudnn-cu12` publish only manylinux and win_amd64 wheels. Install the subset
that resolves (`faster-whisper`, `sounddevice`, `soxr`, `numpy`, `websockets`, `onnxruntime`,
`huggingface_hub`, `sherpa-onnx`) and run `python -m server.app --model base`, then `--model small`.

One more thing belongs in phase 0 because it is cheap and it gates a feature rather than a model: decode
the existing test clips through both faster-whisper and WhisperKit and compare the `avgLogprob` and
word-probability distributions. If they match, the clarity formula and the 0.55 threshold ship unchanged
and a whole column of the parity matrix collapses. If they do not, both constants need re-deriving and
that is better known on day one than in phase 3.

Record every figure twice on the MacBook, plugged in and on battery, and once on the Mini. Three numbers per
model is the point: the Mini is the ceiling, the MacBook on battery is the tier decision, and the ratio
between the two machines is the generational slope that lets the base M1 be estimated rather than guessed.

Exit criteria, as numbers:

- If WhisperKit clears `small` or better comfortably inside 1000 ms on the MacBook on battery, phase 1
  proceeds and the tier is set from the measurement rather than from `ARM-PORT.md`.
- If CPU-only CTranslate2 also clears `small` there, record what the rewrite actually buys before
  committing to it. It is still likely worth doing, for the larger model and the open App Store door, but
  the case is smaller and should be made explicitly rather than assumed.
- If neither clears `small`, macOS gets the `base` tier whatever the engine, and the value of the whole port
  drops enough to be worth reconsidering.

Two traps. The transducer and VAD figures will generalise across machines because `asr_stream._threads()`
caps the recogniser at four threads regardless of core count, but the Metal and Neural Engine figures will
not, so do not let a Mini number set a shipped default. And a plain command-line binary with no `.app`
bundle may be unable to present a TCC dialog on macOS 26, so `python -m server.app` may fail to obtain
microphone permission at all, with a symptom that looks like a broken audio device rather than a missing
prompt. The fix is a minimal `.app` wrapper with an `Info.plist`, not a day inside `audio.py`.

**Phase 1, the first judgeable build.** SwiftUI window, the winning engine with Metal, Silero VAD, microphone
**and** system audio through ScreenCaptureKit. No speakers, no clarity, no compact mode, no picker.

System audio is in phase 1 deliberately. An earlier draft put microphone only in phase 1 and asked the owner
to judge it, which does not work: he routes system audio and a hearing aid through this app every day, so a
microphone-only build can tell him whether Apple Silicon is fast enough but cannot tell him whether this is
Sunno. ScreenCaptureKit rather than the tap, because it works on more machines and does not block on the DTS
answer. Sign it with a real Developer ID identity even for private testing, because TCC grants key to the
signing identity and an ad-hoc build tends to lose its permission on every rebuild, which reads as a
permissions bug and is not one.

**Phase 2, the risk and the decision.** The Core Audio tap behind the capture seam, the DTS answer on
sandboxing, and a stereo capture test through the hearing aid route on the machine running macOS 26 to settle
the channel regression report. Distribution is decided at the end of this phase, on evidence.

**Phase 3, parity.** Speaker labelling through sherpa-onnx, clarity and per-word shading with both thresholds
re-derived from measurement, the model picker with remeasured tables on both machines, compact mode, settings,
diagnostics. Port `tests/test_biquad.py` and `tests/test_hallucinations.py` first, since both are pure logic
and both guard things that break quietly.

**Phase 4, shipping.** Notarisation, hardened runtime, the first-run permission flow, an update mechanism if
Developer ID was chosen, the accessibility audit under VoiceOver, and the base M1 validation pass.

Deliberately not in the plan: the streaming transducer tier and the phone route. Both are carry-overs whose
value is known and neither teaches anything about whether this port works.

---

## What is still unverified

Ordered by damage, with the machine that settles each.

| Claim | How to settle it | Where |
|---|---|---|
| Metal and Neural Engine latency per model against the 1000 ms budget | WhisperKit's own CLI, then the real pipeline | MacBook, on battery. The Mini gives the ceiling only |
| CPU-only CTranslate2 latency, which prices the rewrite | Phase 0, first hour | MacBook, on battery |
| **That WhisperKit's `avgLogprob` and word probabilities have the same distribution as faster-whisper's**, which is what lets the clarity formula and the 0.55 threshold transfer unchanged | Decode the existing test clips through both and compare distributions before trusting either constant | Either |
| Whether the tier chosen on an M1 Pro holds on a base M1, and whether the picker's estimate stays truthful there | Re-run the same bench | **No machine available.** Extrapolate from the two-machine slope now, buy a used M1 Air before shipping |
| Sustained thermal behaviour on a fanless machine over a long meeting | Ninety minutes of continuous captioning | **No machine available.** Neither a Mini nor a 14-inch MacBook Pro reproduces it |
| **Whether ScreenCaptureKit on macOS 26 sums system audio to mono with an external interface** | Capture stereo with the Phonak route active, inspect both channels | Whichever machine holds macOS 26 |
| A Core Audio tap works reliably, and what its prompt says | Build AudioCap, capture ten minutes of a call | Either, on 14.4+ |
| Whether the tap works inside the App Sandbox | File a DTS incident. Failing that, sign a test app with `com.apple.security.app-sandbox` and look for `kAudioHardwareNotPermittedError` | Either |
| Whether the audio-capture TCC bucket is still separate, and the indicator behaviour, on 15 against 26 | Grant one, deny the other, observe | Both, which is why they should stay on different releases |
| What `provider="coreml"` does to the lean tier, which is one string in `asr_stream.py:65` | Re-run `bench/bench_stream_latency.py` with it changed | Either. Do this before any model swap |
| Whether Kyutai STT 1b can serve both tiers at once | Load it in MLX, run ninety minutes on battery, record peak memory, average power and first-committed-word latency | MacBook, on battery |
| Whether Parakeet's transducer confidence can be mapped onto the clarity scale at all | Compare its score distribution against Whisper's `avg_logprob` on the same clips | Either |
| Whether CrisperWhisper's weights can be licensed for this use | Ask Nyra Health. It is CC-BY-NC today, which is a question rather than a wall | Desk work |
| That Claquette reaches system audio through ScreenCaptureKit, the basis for believing the App Store route works | `codesign -d --entitlements -` on it | Either |
| That `disable-library-validation` is in fact an App Store rejection | Only Apple can settle this. Community consensus is strong but not authoritative | DTS |
| Whether ScreenCaptureKit requires a discarded video output for audio-only capture | Try an audio-only `SCStream` and read the log | Either |
| That a plain CLI process cannot raise a TCC prompt on macOS 26 | Phase 0, first microphone open | The macOS 26 machine |
| Whether anything in WhisperKit or Core ML asset loading touches the network unprompted | Run it with the Wi-Fi off after first launch. This is a promise, not a preference | Either |
| The licence on WhisperKit's Core ML weight conversions | Read the model repo before shipping, and give it the treatment `THIRD-PARTY-NOTICES.md` gave Kroko | Desk work |

Three things that were on this list are now settled and have moved into the body: the sherpa-onnx
C API does expose speaker-embedding extraction at the same 512 dimensions, WhisperKit does expose
`avgLogprob` and per-word probability directly, and the Core ML encoder question is moot on a
WhisperKit path because Core ML is the whole runtime rather than an accelerator for part of it.

---

## Landmines

**Measuring only on Pro tier hardware makes the picker lie.** `hardware.py` scales its tables by a measured
`cpu_score`, and a table derived from an M1 Pro and an M4 Pro has never seen the machine most users have. The
failure is not a crash, it is an optimistic estimate shown to someone deciding whether to spend a 3 GB
download, which is the one screen where being wrong costs trust.

**The lag tables fail quietly for unknown ids.** `hardware.py` falls through to
`_UNKNOWN_MODEL_LAG_MS = 5000`, so the picker shows every model as "5 s, not responsive". The ARM port hit
exactly this. Populate the tables before the picker ships.

**`record_latency` and the shipped tables are already on different scales**, and `hardware.py`'s own docstring
says so: the tables are beam 1 without word timestamps, the recorded figures are finals at beam 5 with them,
and the dev box shows a 4.5x gap on one model. Do not reconcile that by remeasuring one side on new hardware
and leaving the other.

**Do not let the two machines drift onto the same macOS release.** The version A/B is the only way to settle
four of the unknowns above, and it is one-way: once both are on 26, getting back to 15 is a reinstall.

**Do not let a device name reach a log.** `audio.py:66-75` and `Diagnostics.cs` both work to keep
"Headset (R-Phonak hearing aid)" out of files a user is asked to send a stranger. A new capture layer is a new
place for that to leak, and on macOS the capture APIs can enumerate other applications by name, a category the
Windows code never had to think about.

**Every Mach-O in the bundle must be signed before the bundle is**, inner first, with `--options runtime` and a
timestamp. This is the macOS equivalent of the staging discipline in `stage-backend.ps1`, and it fails at
notarisation rather than at build time, which is late.
