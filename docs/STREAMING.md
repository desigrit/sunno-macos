# Streaming and correction paths

## What changed

The capture thread conditions each frame once using a stateful high-pass filter and smooth
gain. Frames in the utterance buffer are immutable. The ASR queue may replace stale partial
snapshots, but its per-utterance cursor feeds every new sample exactly once to streaming
engines. Finals flush right context. Pause invalidates queued and in-flight results with a
generation counter; a new stream cannot inherit the preceding capture session's state.

Apple Speech uses a private Swift subprocess and framed PCM pipes, not a network service.
SpeechAnalyzer consumes an asynchronous audio sequence and returns overlapping revisions.
The helper converts 16 kHz float audio into the format requested by Apple's model. Model
retention spans the helper process, while recognition state resets between utterances.
Every IPC exchange has a timeout, including writes. An unresponsive helper is terminated
and restarted on a subsequent decode. Only explicit model setup can download assets.

In hybrid mode the live recognizer and Whisper have separate workers. Final native text is
displayed first. One `correction` event can replace it without creating a line, moving it,
overwriting a later speaker edit, or resurrecting cleared history. Empty, failed, stale and
excess-backlog corrections leave the native text intact. Transcript recordings append
revisions to their crash-safe journal and fold them into one line during export/recovery.

No ASR confidence values are fabricated for Apple Speech. No audio or transcripts are logged
or saved unless the user chooses to record. Asset downloads are the only new network activity.

## Automated checks

Run with the engine's Python environment:

```sh
python tests/test_incremental_asr.py
python tests/test_recording.py
python tests/test_protocol_contract.py
python tests/test_swift_protocol.py
python tests/test_transcript_order.py
python tests/test_capture_recovery.py
node tests/test_browser_recovery.js
SUNNO_TEST_APPLE_SPEECH=1 python tests/test_apple_speech_smoke.py
```

`test_incremental_asr.py` uses fake recognizers and synthetic samples. It covers chunk-invariant
conditioning, coalesced audio updates, state lifetime, adaptive bounds, pause races, bounded
correction queues, failed/empty/expired corrections, and journal replacement without duplicates.
The Swift checks exercise the real transcript store. Native model recognition and real device
switching require a Mac and are not implied by unit-test success.

The opt-in native check generates a spoken sentence locally with `say`; it never captures
the microphone, saves user speech, or downloads models. Apple's English assets must already
be installed. It checks provisional captions, final text, and reset isolation.

### Validation of the 0.3.0 comparison build

On the development Apple-silicon Mac, the native smoke test passed with real Apple models.
The packaged Apple and Whisper large-v3 engines also loaded, finalized synthetic silence,
and closed successfully. Incremental/correction, transcript ordering, recording, capture
recovery, input-switch, state-machine, startup, browser, and protocol checks passed. Four
platform/hardware-specific capture tests were skipped. The ARM64 app's local signature
verified. This is functional validation, not a latency, accuracy, memory, or battery benchmark;
real device switching and long-running hybrid behavior still need hands-on comparison.

## Compare after installing

Select each of these in the same app with the same audio source:

1. Whisper large-v3: snapshot recognition with adaptive scheduling.
2. Apple Speech: native provisional and final text.
3. Apple Speech + Whisper: native text followed by optional large-v3 correction.

Use the same accented-English speech, names and technical vocabulary. Test both conversation
and long webinar turns, on battery and AC. Measure time to first useful text, time to stable
text, correction delay, word errors, unwanted revisions, memory and energy. File-transcription
throughput is not a substitute for these live-caption measurements.

Also exercise pause during recognition/correction, clearing history, switching input, changing
models, unavailable system assets, and ending a recording while a correction is in flight.
Skipped corrections must not delete the original words; a changed model must not rewrite the
previous session. No speedup or accuracy improvement is claimed before that comparison.
