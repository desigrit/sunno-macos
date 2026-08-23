"""The Swift decoders, checked against the backend that defines the protocol.

This is the other half of `tests/test_protocol_contract.py`, which sits beside the engine
because that is where the wire is defined, and which holds the only declaration of what goes
on it. This file imports that declaration and points its parser at the Swift.

**It deliberately does not carry a copy of the schema.** Two declarations of one contract
drift, quietly, and drifting is precisely the failure the schema exists to catch. If this
file ever grows its own copy of `SCHEMA`, the check has been turned into decoration.

What it catches is the class of mistake a Swift compiler cannot see. A wire name that differs
by an underscore compiles cleanly and then decodes to nil, which on a caption means a line
with no speaker and no clarity: the feature looks broken rather than misspelt. Neither
language can see the other, so the check has to live above both, and the submodule is what
puts them in the same tree long enough to compare.

Needs no venv and no Xcode. It reads text.

Run: python tests/test_swift_protocol.py
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
CONTRACT = HERE / "tests" / "test_protocol_contract.py"


def load_contract():
    """Import the backend repository's contract module, with its paths aimed here.

    Loaded by path rather than by name, so nothing is added to `sys.path`: putting the
    repository root there would make `import server` resolve, which is how a test that is
    supposed to read source text ends up importing ctranslate2 instead.
    """
    if not CONTRACT.is_file():
        return None

    spec = importlib.util.spec_from_file_location("sunno_contract", CONTRACT)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    # The module defaults to looking for the client in a `mac/` directory beside the engine,
    # which is where it used to live. Here the client and the engine share a repository, so
    # both roots are this one.
    module.SWIFT_ROOT = HERE
    module.ROOT = HERE
    module.SERVER = HERE / "server"
    return module


def main() -> int:
    contract = load_contract()
    if contract is None:
        print(f"Could not load {CONTRACT}.")
        return 1

    failures: list[str] = []

    # --- events -------------------------------------------------------------------
    declared = set(contract.SCHEMA)
    kinds = contract.swift_event_kinds()
    if kinds is None:
        failures.append("Sunno/Protocol/Events.swift not found. This repository is the client, "
                        "so its absence is a broken checkout rather than a skip.")
        kinds = {}

    swift_wire = set(kinds) - {"unknown"}

    for name in sorted(swift_wire - declared):
        failures.append(
            f"Events.swift decodes '{name}', which the backend never emits. Either it was "
            f"renamed upstream and not here, or the Swift case is dead.")
    for name in sorted(declared - swift_wire):
        failures.append(
            f"Events.swift has no case for '{name}'. It falls through to .unknown and is "
            f"dropped on the floor.")
    if kinds and "unknown" not in kinds:
        failures.append(
            "Events.swift has no 'unknown' case. Without it a newer backend breaks an older "
            "client rather than being ignored by it, which is the wrong direction for an app "
            "somebody is relying on mid-conversation.")

    # --- fields -------------------------------------------------------------------
    known = {f for spec in contract.SCHEMA.values() for f in spec["fields"]}
    known.update(contract.CATALOG_FIELDS)
    known.update(["t", "p"])                # word entries
    known.update(["named", "is_self"])      # roster entries
    known.add("type")                       # the discriminator itself

    for name in sorted(contract.swift_coding_keys() - known):
        failures.append(
            f"Events.swift maps a field '{name}' that appears nowhere in the schema. A "
            f"misspelt wire name decodes to nil rather than failing.")

    # --- the device list, which travels over HTTP rather than the socket ----------
    device_keys = contract.swift_device_keys()
    if device_keys is None:
        failures.append("Sunno/Services/DeviceCatalog.swift not found")
    else:
        for name in sorted(device_keys - contract.DEVICE_FIELDS):
            failures.append(
                f"DeviceCatalog.swift decodes a device field '{name}' the backend never sends. "
                f"It is silently nil, and on `loopback` that means system audio endpoints get "
                f"offered as microphones.")
        missing = contract.DEVICE_FIELDS_USED_BY_CLIENTS - device_keys
        if missing:
            failures.append(
                f"DeviceCatalog.swift ignores {sorted(missing)}, which a picker needs to tell "
                f"microphones from output endpoints and to mark the system default.")

    print("Engine read from server/, in this repository")
    print(f"  schema:   {len(declared)} event types, imported, not copied")
    print(f"  swift:    {len(swift_wire)} event cases, "
          f"{len(contract.swift_coding_keys())} wire fields")
    if device_keys is not None:
        print(f"  devices:  {len(device_keys)} fields decoded")

    if failures:
        print("\nFAIL")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("\nOK: the Swift decoders match the backend that produces the protocol.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
