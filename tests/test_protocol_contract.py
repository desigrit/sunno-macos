"""The WebSocket contract, pinned against the backend that produces it.

Every client Sunno has speaks the same protocol: the browser page in ``ui/app.js``, the
WinUI app through ``CaptionClient.cs``, and a Swift app on macOS. Three consumers of one
producer, and nothing until now checked that they agreed about it.

That mattered less when the only consumer lived in the same repository as its producer and
the same person changed both in one commit. It matters now, because the macOS client is a
separate language in a separate repository with its own hand-written decoders: a field
renamed in ``app.py`` is a silently missing caption on the Mac, not a build error, and the
symptom shows up as "the app stopped working" from someone in a meeting.

**This file is where the contract lives.** ``SCHEMA`` below is the single declaration of what
goes on the wire, and it stays in this repository because this is where the wire is defined.
The macOS repository does not copy it: ``desigrit/sunno-macos`` carries this repository as a
submodule and imports ``SCHEMA`` from this file to check its Swift decoders against. Two
copies of a schema drift, and drifting is the exact failure the schema exists to catch, so
there is deliberately only one.

What runs here is the producer half: every event the backend can emit, checked against the
declaration. The Swift half runs in the other repository, where the Swift is.

It is deliberately static. Importing ``server.app`` drags in ctranslate2, sounddevice and the
rest, none of which need to exist to answer "what does this thing put on the wire". That also
means it runs on any machine with a bare Python, which is the machine most likely to be
checking.

Two directions of failure, both caught:

  * the backend emits a type the schema has never heard of, which is the new-feature case
    and means a client has been left behind;
  * the schema declares a type the backend no longer emits, which is the dead-code case and
    means a client is carrying a decoder for something that will never arrive.

What it deliberately does NOT check is field-level shape, because the fields are assembled
across ``pipeline.py`` and ``app.py`` at runtime and any static reading of them would be a
guess dressed as a test. The field lists below are documentation for whoever writes the next
client, and are marked as such.

Run: python tests/test_protocol_contract.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "server"

# Every event the backend can put on the socket.
#
# `fields` is a note for the next client author rather than an assertion. `optional` marks
# fields that are genuinely absent on some emissions of the same type, which is the detail a
# strict decoder in another language gets wrong first: `status` carries `model` and `device`
# only once there is a model and a device, and `error` carries `code` and `detail` only when
# the failure is one the UI can offer a fix for.
SCHEMA: dict[str, dict] = {
    "status": {
        "fields": ["state", "running", "model", "device"],
        "optional": ["running", "model", "device"],
        "note": "state is one of starting, loading, listening, stopped.",
    },
    "partial": {
        "fields": ["id", "text", "speaker_id", "speaker", "clarity",
                   "latency_ms", "duration_s", "started_at", "words"],
        "optional": ["speaker_id", "speaker", "clarity"],
        "note": "Provisional text. clarity is null on the streaming engines. words is empty "
                "on partials: only the final pass asks for word timestamps.",
    },
    "final": {
        "fields": ["id", "text", "speaker_id", "speaker", "clarity",
                   "latency_ms", "duration_s", "started_at", "words"],
        "optional": ["speaker_id", "speaker", "clarity"],
        "note": "Replaces the partial with the same id exactly once. words is a list of "
                "{t, p}: token text and probability.",
    },
    "discard": {
        "fields": ["id"],
        "optional": [],
        "note": "The utterance with this id will never arrive. Too short, or capture stopped.",
    },
    "speech_start": {
        "fields": ["id"],
        "optional": [],
        "note": "Voice detected. No client currently renders this; it exists for latency work.",
    },
    "level": {
        "fields": ["rms", "db", "speech_prob", "speaking"],
        "optional": [],
        "note": "About 10 Hz. Drives the input meter.",
    },
    "roster": {
        "fields": ["speakers"],
        "optional": [],
        "note": "speakers is a list of {id, label, named, is_self}. Sent whenever it changes.",
    },
    "speaker_merged": {
        "fields": ["from", "into"],
        "optional": [],
        "note": "Always sent BEFORE the roster that follows it. A client must move already "
                "displayed lines from one id to the other first, because the merged-away id "
                "is gone from the roster and a relabel pass would skip those lines forever. "
                "'from' is a reserved word in several languages; decoders need to alias it.",
    },
    "speaker_deleted": {
        "fields": ["id", "label"],
        "optional": [],
        "note": "Also sent before the roster, for the same reason as speaker_merged.",
    },
    "model_required": {
        "fields": ["requested", "device", "catalog"],
        "optional": [],
        "note": "First run. No model on disk, so nothing can start until one is chosen.",
    },
    "model_catalog": {
        "fields": ["current", "device", "catalog"],
        "optional": [],
        "note": "Answer to the list_models command. Same catalog shape as model_required.",
    },
    "download_started": {"fields": ["model"], "optional": [], "note": ""},
    "download_progress": {
        "fields": ["model", "downloaded", "total", "percent"],
        "optional": [],
        "note": "Throttled to about 10 Hz by the backend.",
    },
    "download_complete": {"fields": ["model"], "optional": [], "note": ""},
    "download_failed": {"fields": ["model", "message"], "optional": [], "note": ""},
    "recording": {
        "fields": ["state", "elapsed_s", "folder", "name", "duration_s", "lines", "message"],
        "optional": ["elapsed_s", "folder", "name", "duration_s", "lines", "message"],
        "note": "state is idle, recording, saving, saved or failed, and which fields are "
                "present depends on it: 'recording' carries elapsed_s and folder, 'saved' "
                "carries name, folder, duration_s and lines, 'failed' carries message. "
                "elapsed_s is the length of audio written, not wall-clock time since the "
                "button was pressed; the two differ whenever capture stops and starts inside "
                "one recording. 'folder' is handed straight back as the resume argument when "
                "the engine is restarted for a new microphone or model, which is what keeps "
                "one recording from becoming two.",
    },
    "error": {
        "fields": ["message", "code", "detail", "running"],
        "optional": ["code", "detail", "running"],
        "note": "code is mic_denied, mic_unavailable or capture_failed when the UI can offer "
                "a specific fix, and absent otherwise.",
    },
}

# Commands a client may send. Extracted from the handler's own comparisons, so this side is
# checked the same way the event side is.
COMMANDS = {
    "start", "stop", "toggle", "download_model", "list_models",
    "rename_speaker", "set_self", "merge_speakers", "delete_speaker", "reset_speakers",
    "start_recording", "stop_recording",
}

# Entries in a catalog list, from models.catalog_with_status. Documentation only: this one is
# built with dict(entry, ...) so no literal in the source names the keys together.
CATALOG_FIELDS = [
    "id", "name", "detail", "approx_mb", "languages",
    "available", "lag_ms", "lag_text", "responsive", "auto_select",
]

# The other thing a client decodes: the device list, served over HTTP rather than the socket.
#
# Assembled across three places. audio.list_input_devices builds the common fields,
# audio._mark_default adds is_default_input, and loopback.list_loopback_devices produces the
# output endpoints with is_default_output and loopback=True. app.py then sets loopback=False
# on the microphone entries so a client can tell the two apart without inferring it.
DEVICE_FIELDS = {
    "index", "name", "channels", "default_samplerate", "hostapi",
    "is_default_input", "is_default_output", "loopback",
}

# Fields a client is allowed to rely on. Deliberately narrower than what is served: `hostapi`
# is a Windows concept, and `channels` and `default_samplerate` describe the capture format
# rather than anything a picker should show.
DEVICE_FIELDS_USED_BY_CLIENTS = {
    "index", "name", "loopback", "is_default_input", "is_default_output",
}


def device_fields_in_source() -> set[str]:
    """Keys the backend actually puts in a device entry."""
    found: set[str] = set()
    for name in ("audio.py", "loopback.py", "app.py"):
        text = (SERVER / name).read_text(encoding="utf-8")
        # Dict literals keyed by string, plus the d["..."] = assignments used for the flags.
        found.update(re.findall(r'"(index|name|channels|default_samplerate|hostapi|'
                                r'is_default_input|is_default_output|loopback)"', text))
    return found


def swift_device_keys() -> set[str] | None:
    """Wire names the Swift DeviceCatalog decodes. None when it is not in this checkout."""
    path = _swift_devices_path()
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")

    names: set[str] = set()
    for block in re.findall(r"enum CodingKeys[^{]*\{(.*?)\n\s*\}", text, re.S):
        for line in block.splitlines():
            line = line.strip()
            if not line.startswith("case "):
                continue
            rest = line[len("case "):].strip()
            if "=" in rest:
                _, _, raw = rest.partition("=")
                names.add(raw.strip().strip('"'))
            else:
                for name in (n.strip() for n in rest.split(",")):
                    if name and name.isidentifier():
                        names.add(name)
    return names



def _sources() -> list[Path]:
    return sorted(p for p in SERVER.glob("*.py") if p.name != "__init__.py")


# Where the Swift client lives, when it is reachable from here.
#
# It normally is not: the macOS app lives in desigrit/sunno-macos, which pins this repository
# as a submodule, imports this module, and reassigns SWIFT_ROOT to its own checkout before
# calling the readers below. That is why this is one overridable constant rather than two
# hardcoded paths: the schema has exactly one home, and the repository that holds the Swift
# points the parser at it rather than copying the declaration.
#
# The default still works for a checkout that happens to have the client beside it, and a
# checkout with neither skips cleanly instead of failing.
SWIFT_ROOT = ROOT / "mac"


def _swift_events_path() -> Path:
    return SWIFT_ROOT / "Sunno" / "Protocol" / "Events.swift"


def _swift_devices_path() -> Path:
    return SWIFT_ROOT / "Sunno" / "Services" / "DeviceCatalog.swift"


def swift_event_kinds() -> dict[str, str] | None:
    """Wire name -> Swift case name, read out of the `Kind` enum. None when absent."""
    events = _swift_events_path()
    if not events.is_file():
        return None
    text = events.read_text(encoding="utf-8")

    start = text.find("enum Kind")
    if start < 0:
        return {}
    end = text.find("\n    }", start)
    body = text[start:end if end > 0 else len(text)]

    kinds: dict[str, str] = {}
    # `case speechStart = "speech_start"` and bare `case status`, which is its own wire name.
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        rest = line[len("case "):].strip()
        if "=" in rest:
            name, _, raw = rest.partition("=")
            kinds[raw.strip().strip('"')] = name.strip()
        else:
            for name in (n.strip() for n in rest.split(",")):
                if name and name.isidentifier():
                    kinds[name] = name
    return kinds


def swift_coding_keys() -> set[str]:
    """Every wire name the Swift decoder knows, across all its CodingKeys blocks."""
    events = _swift_events_path()
    if not events.is_file():
        return set()
    text = events.read_text(encoding="utf-8")

    names: set[str] = set()
    for block in re.findall(r"enum CodingKeys[^{]*\{(.*?)\n\s*\}", text, re.S):
        for line in block.splitlines():
            line = line.strip()
            if not line.startswith("case "):
                continue
            rest = line[len("case "):].strip()
            if "=" in rest:
                # `case speakerId = "speaker_id"` - the wire name is the literal.
                _, _, raw = rest.partition("=")
                names.add(raw.strip().strip('"'))
            else:
                # `case id, label, named` - each identifier is its own wire name.
                for name in (n.strip() for n in rest.split(",")):
                    if name and name.isidentifier():
                        names.add(name)
    return names



def emitted_types() -> dict[str, set[str]]:
    """Every ``"type": "..."`` literal in the backend, mapped to the files it appears in.

    A literal match rather than an AST walk, deliberately. The events are assembled in three
    different shapes - a dict literal passed straight to emit(), a dict built and stored in
    latest_status, and a conditional expression picking between two names - and the one thing
    all of them have in common is the literal key.

    The conditional is why ``"final" if job.is_final else "partial"`` needs its own pattern:
    the type is two string literals rather than one, so a naive search for `"type": "x"` finds
    neither.
    """
    found: dict[str, set[str]] = {}
    literal = re.compile(r'"type":\s*"([a-z_]+)"')
    conditional = re.compile(r'"type":\s*"([a-z_]+)"\s+if\s+.+?\s+else\s+"([a-z_]+)"')

    for path in _sources():
        text = path.read_text(encoding="utf-8")
        names = set(literal.findall(text))
        for a, b in conditional.findall(text):
            names.update((a, b))
        for name in names:
            found.setdefault(name, set()).add(path.name)
    return found


def handled_commands() -> set[str]:
    """Command strings the websocket handler compares against."""
    text = (SERVER / "app.py").read_text(encoding="utf-8")
    return set(re.findall(r'cmd\s*==\s*"([a-z_]+)"', text))


def main() -> int:
    failures: list[str] = []

    emitted = emitted_types()
    declared = set(SCHEMA)
    actual = set(emitted)

    for name in sorted(actual - declared):
        failures.append(
            f"backend emits '{name}' ({', '.join(sorted(emitted[name]))}) but the schema "
            f"here does not declare it. Every client needs to learn about it, including "
            f"the macOS one."
        )

    for name in sorted(declared - actual):
        failures.append(
            f"schema declares '{name}' but no file under server/ emits it any more. "
            f"Clients are carrying a decoder for something that will never arrive."
        )

    commands = handled_commands()
    for name in sorted(commands - COMMANDS):
        failures.append(f"backend handles command '{name}' which this test does not declare")
    for name in sorted(COMMANDS - commands):
        failures.append(f"test declares command '{name}' which the backend no longer handles")

    # The ordering guarantee is load-bearing and is expressed only as a comment in app.py, so
    # it is asserted here too. If either announcement stops preceding its roster, a client
    # that relabels by id silently strands captions under a name the user asked to remove.
    app = (SERVER / "app.py").read_text(encoding="utf-8")
    for kind in ("speaker_merged", "speaker_deleted"):
        pos = app.find(f'"type": "{kind}"')
        if pos < 0:
            continue
        roster_after = app.find('"type": "roster"', pos)
        if roster_after < 0:
            failures.append(f"'{kind}' is emitted with no roster following it")

    print(f"Checked {len(_sources())} backend source files")
    print(f"  event types: {len(actual)} emitted, {len(declared)} declared")
    print(f"  commands:    {len(commands)} handled, {len(COMMANDS)} declared")
    print(f"  catalog:     {len(CATALOG_FIELDS)} fields documented")

    # --- the Swift client, if this checkout has one ---------------------------------
    #
    # The macOS app hand-writes its decoders, so a wire name that differs by an underscore
    # compiles cleanly and then silently decodes to nil. On a caption that means a line with
    # no speaker and no clarity, which reads as the feature being broken rather than as a
    # typo. Nothing else in the toolchain can catch it: Swift cannot see the Python, and the
    # Python cannot see the Swift, so the check has to live above both.
    kinds = swift_event_kinds()
    if kinds is None:
        print("  swift:       not in this checkout, checked from desigrit/sunno-macos instead")
    else:
        swift_wire = set(kinds) - {"unknown"}
        for name in sorted(swift_wire - declared):
            failures.append(
                f"Events.swift decodes '{name}', which the backend never emits. Either it "
                f"was renamed here and not there, or the Swift case is dead."
            )
        for name in sorted(declared - swift_wire):
            failures.append(
                f"Events.swift has no case for '{name}'. It will fall through to .unknown "
                f"and be dropped on the floor by the macOS client."
            )
        if "unknown" not in kinds:
            failures.append(
                "Events.swift has no 'unknown' case. Without it a newer backend breaks an "
                "older client rather than being ignored by it, which is the wrong direction "
                "for an app someone is relying on mid-conversation."
            )

        known_fields = {f for spec in SCHEMA.values() for f in spec["fields"]}
        known_fields.update(CATALOG_FIELDS)
        known_fields.update(["t", "p"])                       # word entries
        known_fields.update(["named", "is_self"])             # roster entries
        known_fields.add("type")                              # the discriminator itself

        swift_keys = swift_coding_keys()
        for name in sorted(swift_keys - known_fields):
            failures.append(
                f"Events.swift maps a field '{name}' that appears nowhere in this schema. "
                f"A misspelt wire name decodes to nil rather than failing."
            )
        print(f"  swift:       {len(swift_wire)} event cases, {len(swift_keys)} wire fields")

    # --- the device list, which travels over HTTP rather than the socket ---
    served = device_fields_in_source()
    for name in sorted(DEVICE_FIELDS - served):
        failures.append(
            f"device entries no longer carry '{name}', but this test still declares it")
    for name in sorted(served - DEVICE_FIELDS):
        failures.append(
            f"device entries carry '{name}', which this test does not declare")

    device_keys = swift_device_keys()
    if device_keys is not None:
        for name in sorted(device_keys - DEVICE_FIELDS):
            failures.append(
                f"DeviceCatalog.swift decodes a device field '{name}' that the backend never "
                f"sends. It will silently be nil, and on `loopback` that means system audio "
                f"endpoints get offered as microphones.")
        missing = DEVICE_FIELDS_USED_BY_CLIENTS - device_keys
        if missing:
            failures.append(
                f"DeviceCatalog.swift ignores {sorted(missing)}, which a picker needs to tell "
                f"microphones from output endpoints and to mark the system default.")
        print(f"  devices:     {len(served)} fields served, {len(device_keys)} decoded in Swift")

    if failures:
        print("\nFAIL")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("\nOK: the wire protocol matches what every client was written against.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
