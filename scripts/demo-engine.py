#!/usr/bin/env python3
"""A stand-in engine that drives the interface for documentation screenshots.

    ./scripts/demo-engine.py &
    SUNNO_ATTACH=1 open -a dist/Sunno.app

It speaks the same WebSocket protocol the real engine does and replays a scripted
conversation, so the app renders it through exactly the code paths a real session uses:
`final` events with per-word confidence, a `roster` with named speakers, and `level` events so
the meter moves.

**Why this exists rather than a recording.** The screenshots need four labelled speakers, and
speaker labelling cannot be demonstrated with synthesised speech. Measured with the CAM++
embeddings the app actually uses, macOS `say` voices score 0.586 mean cosine similarity to
themselves and 0.487 to each other — distributions that overlap almost completely, because
every one of those voices comes out of the same synthesiser and a model trained on human
speech has nothing to separate. No threshold works. Recording four people over dinner is the
only way to produce that screenshot from real audio, and it is not a reasonable prerequisite
for updating a README.

**Why it is here and not in `server/`.** This fabricates captions, and an app people rely on
to know what was said should not carry code that can invent them. `scripts/` is not copied
into the bundle by `package-app.sh`, so this cannot ship even by accident.

The transcript is the one from the Windows README, so the two platforms' screenshots show the
same conversation.
"""

import asyncio
import json
import sys
from pathlib import Path

PORT = 8766

SPEAKERS = [
    {"id": 0, "label": "Priya", "named": True, "is_self": False},
    {"id": 1, "label": "Marco", "named": True, "is_self": False},
    {"id": 2, "label": "You", "named": True, "is_self": True},
    {"id": 3, "label": "Sarah", "named": True, "is_self": False},
]

# (speaker id, text, clarity or None, uncertain words)
#
# Clarity appears on the two lines the Windows screenshot shows it on. The uncertain words are
# the ones the transcript renders grey, italic and underlined; a probability below 0.62 is what
# the view treats as uncertain.
SCRIPT = [
    (3, "Marco, be honest with me. What was actually in that lasagne?", None, {}),
    (1, "Love. Mostly love.", None, {}),
    (0, "There was a bay leaf in mine roughly the size of a postcard.", None, {}),
    (2, "I assumed that was a garnish, so I ate it.", 92, {}),
    (1, "You ate the bay leaf.", None, {}),
    (2, "I ate the entire bay leaf.", 95, {}),
    (3, "And this is why we do not let him order for the table.", None, {}),
]


def words_for(text: str, uncertain: dict[str, float]) -> list[dict]:
    """Word tokens as Whisper produces them, which is to say with the space attached.

    Whisper's tokenizer emits " Marco", not "Marco", and the transcript view concatenates
    tokens verbatim rather than joining them — correctly, because that is the only way to
    reproduce the original spacing around punctuation and contractions. Dropping the leading
    space here produces a caption reading "Marco,behonestwithme", which is what the first run
    of this script did.
    """
    return [
        {"t": (" " if i else "") + w, "p": uncertain.get(w.strip(".,?!"), 0.97)}
        for i, w in enumerate(text.split())
    ]


def catalog() -> list[dict]:
    """The real catalogue, from the real engine, for the machine this is running on."""
    # The repo root, not the current directory: this script lives in scripts/, so Python puts
    # scripts/ on the path and `server` is invisible from wherever it happens to be run.
    root = str(Path(__file__).resolve().parent.parent)
    if root not in sys.path:
        sys.path.insert(0, root)
    from server import models

    return models.catalog_with_status("cpu")


async def handler(ws):
    print(f"    client connected", flush=True)
    await ws.send(json.dumps({
        "type": "status", "state": "listening", "running": True,
        "model": "small", "device": "MacBook Pro Microphone (16000 Hz)",
    }))
    await ws.send(json.dumps({"type": "roster", "speakers": SPEAKERS}))

    async def commands():
        # The picker asks for the catalogue when it opens. Serve the real one, computed by the
        # real code from the real weights on this machine, so the sizes and the "installed"
        # ticks in a screenshot are true. Everything else is accepted and ignored: a stand-in
        # that closed the socket on an unrecognised command would look like a crashed engine.
        try:
            async for raw in ws:
                try:
                    cmd = json.loads(raw).get("cmd")
                except (TypeError, ValueError):
                    continue
                print(f"    <- {cmd}", flush=True)
                if cmd == "list_models":
                    try:
                        entries = catalog()
                    except Exception as exc:
                        print(f"    !! catalogue failed: {exc!r}", flush=True)
                        continue
                    await ws.send(json.dumps({
                        "type": "model_catalog",
                        "current": "small",
                        "device": "cpu",
                        "catalog": entries,
                    }))
                    print(f"    -> catalogue, {len(entries)} models", flush=True)
        except Exception as exc:
            print(f"    !! command loop ended: {exc!r}", flush=True)

    asyncio.create_task(commands())
    await asyncio.sleep(1.2)

    if "--empty" in sys.argv:
        # The "nothing said yet" state: a roster, because these people have been named in an
        # earlier session, but no captions.
        print("    empty state — take the screenshot now", flush=True)
    else:
        await deliver(ws)

    # Idle with a live meter so the window looks like a running session rather than a
    # finished one, and the timer keeps counting.
    while True:
        await ws.send(json.dumps({
            "type": "level", "rms": 0.012, "db": -38.0,
            "speech_prob": 0.04, "speaking": False,
        }))
        await asyncio.sleep(0.4)


async def deliver(ws):
    for i, (sid, text, clarity, uncertain) in enumerate(SCRIPT):
        await ws.send(json.dumps({"type": "speech_start"}))
        # A partial first, then the final that replaces it, which is what the real engine does
        # and what the view's replace-on-final path expects.
        for cut in (0.45, 0.8):
            await ws.send(json.dumps({
                "type": "partial", "id": i,
                "text": " ".join(text.split()[: max(1, int(len(text.split()) * cut))]),
                "speaker_id": sid,
            }))
            await asyncio.sleep(0.25)
        await ws.send(json.dumps({
            "type": "final", "id": i, "text": text,
            "speaker_id": sid, "speaker": SPEAKERS[sid]["label"],
            "clarity": clarity, "latency_ms": 370.0, "duration_s": 2.6,
            "words": words_for(text, uncertain),
        }))
        print(f"    [{SPEAKERS[sid]['label']}] {text}", flush=True)
        await asyncio.sleep(0.7)

    print("\n    transcript delivered — take the screenshots now", flush=True)


async def main() -> int:
    import websockets

    print(f"==> demo engine on ws://127.0.0.1:{PORT}")
    print("    start the app with SUNNO_ATTACH=1 so it does not spawn a real one")
    async with websockets.serve(handler, "127.0.0.1", PORT):
        await asyncio.Future()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        pass
