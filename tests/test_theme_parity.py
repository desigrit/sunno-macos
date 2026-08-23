"""The macOS palette, checked against the Windows one it was copied from.

`Sunno/Theme.swift` carries the same colours as the Windows app's `App.xaml`: the brand ink
in its light and dark forms, eight speaker hues and three clarity bands. They were transcribed
by hand, which is a bad way to move twenty-two hex values between two files that no compiler
reads together, and now between two repositories as well.

The Windows side is reached through the `external/sunno` submodule rather than copied here,
for the same reason the protocol schema is: a second copy of a value is a second thing to
drift, and drift is what this exists to catch.

The failure it guards against is quiet rather than loud. A wrong digit in a speaker hue does
not crash anything; it makes two people in a four-way conversation slightly closer in colour,
on the one screen whose whole job is telling them apart. A wrong clarity threshold shows
somebody a green badge for a decode the model was unsure about. Neither surfaces as an error,
and both are wrong in the direction of looking fine.

The same argument covers the two numeric rules that live in both codebases: the caption
opacities and the low-confidence threshold. Those came from measurement and are quoted in
comments on both sides, so they are pinned here too.

Run: python tests/test_theme_parity.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
SUBMODULE = HERE / "external" / "sunno"
XAML = SUBMODULE / "app" / "App.xaml"
SWIFT = HERE / "Sunno" / "Theme.swift"


def xaml_brushes() -> dict[str, str]:
    """Brush key -> uppercase RRGGBB, from the WinUI resource dictionary.

    The two theme dictionaries both define SunnoInkBrush, so they are disambiguated by the
    dictionary they sit in. WinUI names the dark one "Default", which is not obvious and is
    exactly the sort of thing a hand copy gets backwards.
    """
    text = XAML.read_text(encoding="utf-8-sig")
    brushes: dict[str, str] = {}

    for key, block in re.findall(
        r'<ResourceDictionary x:Key="(Default|Light|HighContrast)">(.*?)</ResourceDictionary>',
        text, re.S,
    ):
        for name, colour in re.findall(
            r'<SolidColorBrush x:Key="(\w+)"\s+Color="#([0-9A-Fa-f]{6})"', block
        ):
            # "Default" is WinUI's name for the dark theme.
            theme = "Dark" if key == "Default" else key
            brushes[f"{theme}.{name}"] = colour.upper()

    # The flat brushes outside the theme dictionaries: speakers and clarity.
    tail = text.split("</ResourceDictionary.ThemeDictionaries>")[-1]
    for name, colour in re.findall(
        r'<SolidColorBrush x:Key="(\w+)"\s+Color="#([0-9A-Fa-f]{6})"', tail
    ):
        brushes[name] = colour.upper()

    return brushes


def swift_hexes() -> dict[str, list[str]]:
    """Named hex literals from Theme.swift, as uppercase RRGGBB."""
    text = SWIFT.read_text(encoding="utf-8")
    out: dict[str, list[str]] = {}

    ink = re.search(r"static let ink = dynamic\(light: 0x([0-9A-Fa-f]{6}),\s*dark: 0x([0-9A-Fa-f]{6})", text)
    if ink:
        out["ink"] = [ink.group(1).upper(), ink.group(2).upper()]

    subtle = re.search(
        r"static let inkSubtle = dynamic\(light: 0x([0-9A-Fa-f]{6}),\s*dark: 0x([0-9A-Fa-f]{6}),"
        r"\s*lightAlpha: ([0-9.]+),\s*darkAlpha: ([0-9.]+)", text)
    if subtle:
        out["inkSubtle"] = [subtle.group(1).upper(), subtle.group(2).upper(),
                            subtle.group(3), subtle.group(4)]

    block = re.search(r"speakerHexes: \[Int\] = \[(.*?)\]", text, re.S)
    if block:
        out["speakers"] = [h.upper() for h in re.findall(r"0x([0-9A-Fa-f]{6})", block.group(1))]

    for name in ("clarityGood", "clarityMid", "clarityLow"):
        m = re.search(rf"static let {name}\s*=\s*Color\(hex: 0x([0-9A-Fa-f]{{6}})\)", text)
        if m:
            out[name] = [m.group(1).upper()]

    return out


def swift_numbers() -> dict[str, str]:
    text = SWIFT.read_text(encoding="utf-8")
    out: dict[str, str] = {}

    m = re.search(r"lowConfidenceBelow: Double = ([0-9.]+)", text)
    if m:
        out["lowConfidenceBelow"] = m.group(1)

    m = re.search(r"if isSelf \{ return isFinal \? ([0-9.]+) : ([0-9.]+) \}", text)
    if m:
        out["selfFinal"], out["selfPartial"] = m.group(1), m.group(2)

    m = re.search(r"return isFinal \? ([0-9.]+) : ([0-9.]+)\n", text)
    if m:
        out["otherFinal"], out["otherPartial"] = m.group(1), m.group(2)

    good = re.search(r"if clarity >= (\d+) \{ return clarityGood \}", text)
    mid = re.search(r"if clarity >= (\d+) \{ return clarityMid \}", text)
    if good:
        out["clarityGoodAt"] = good.group(1)
    if mid:
        out["clarityMidAt"] = mid.group(1)

    return out


def windows_numbers() -> dict[str, str]:
    """The same rules as the Windows app states them, read through the submodule."""
    out: dict[str, str] = {}

    cs = (SUBMODULE / "app" / "MainWindow.xaml.cs").read_text(encoding="utf-8-sig")
    m = re.search(r"isSelf \? \(isFinal \? ([0-9.]+) : ([0-9.]+)\) : \(isFinal \? ([0-9.]+) : ([0-9.]+)\)", cs)
    if m:
        out["selfFinal"], out["selfPartial"] = m.group(1), m.group(2)
        out["otherFinal"], out["otherPartial"] = m.group(3), m.group(4)

    good = re.search(r">= (\d+) => \"ClarityGood\"", cs)
    mid = re.search(r">= (\d+) => \"ClarityMid\"", cs)
    if good:
        out["clarityGoodAt"] = good.group(1)
    if mid:
        out["clarityMidAt"] = mid.group(1)

    cfg = (SUBMODULE / "server" / "config.py").read_text(encoding="utf-8")
    m = re.search(r"low_confidence_below: float = ([0-9.]+)", cfg)
    if m:
        out["lowConfidenceBelow"] = m.group(1)

    return out


def main() -> int:
    if not SUBMODULE.is_dir() or not XAML.is_file():
        print("external/sunno is missing or empty. Run:")
        print("  git submodule update --init --recursive")
        return 1
    if not SWIFT.is_file():
        print(f"{SWIFT} not found. This repository is the client, so that is a broken "
              f"checkout rather than a skip.")
        return 1

    failures: list[str] = []
    xaml = xaml_brushes()
    swift = swift_hexes()

    def compare(label: str, want: str | None, got: str | None) -> None:
        if want is None:
            failures.append(f"{label}: not found in App.xaml, the parser needs updating")
        elif got is None:
            failures.append(f"{label}: not found in Theme.swift, the parser needs updating")
        elif want != got:
            failures.append(f"{label}: App.xaml has #{want}, Theme.swift has #{got}")

    compare("ink (light)", xaml.get("Light.SunnoInkBrush"), (swift.get("ink") or [None])[0])
    compare("ink (dark)", xaml.get("Dark.SunnoInkBrush"),
            (swift.get("ink") or [None, None])[1] if len(swift.get("ink", [])) > 1 else None)

    subtle = swift.get("inkSubtle", [])
    if len(subtle) == 4:
        compare("inkSubtle (light)", xaml.get("Light.SunnoInkSubtleBrush"), subtle[0])
        compare("inkSubtle (dark)", xaml.get("Dark.SunnoInkSubtleBrush"), subtle[1])
        # Opacities live in the XAML as an attribute rather than in the colour.
        xt = XAML.read_text(encoding="utf-8-sig")
        for theme, want_idx, key in (("Light", 2, "Light"), ("Default", 3, "Dark")):
            m = re.search(
                rf'<ResourceDictionary x:Key="{theme}">.*?SunnoInkSubtleBrush"[^>]*Opacity="([0-9.]+)"',
                xt, re.S)
            if m and m.group(1) != subtle[want_idx]:
                failures.append(
                    f"inkSubtle opacity ({key}): App.xaml has {m.group(1)}, "
                    f"Theme.swift has {subtle[want_idx]}")
    else:
        failures.append("inkSubtle: could not be read out of Theme.swift")

    speakers = swift.get("speakers", [])
    if len(speakers) != 8:
        failures.append(f"speaker palette: expected 8 hues in Theme.swift, found {len(speakers)}")
    for i, got in enumerate(speakers):
        compare(f"Speaker{i}", xaml.get(f"Speaker{i}"), got)

    for name, key in (("clarityGood", "ClarityGood"),
                      ("clarityMid", "ClarityMid"),
                      ("clarityLow", "ClarityLow")):
        compare(key, xaml.get(key), (swift.get(name) or [None])[0])

    # --- the numeric rules, which also live in two places ---
    want_numbers = windows_numbers()
    got_numbers = swift_numbers()
    for key, want in sorted(want_numbers.items()):
        got = got_numbers.get(key)
        if got is None:
            failures.append(f"{key}: not found in Theme.swift")
        elif float(want) != float(got):
            failures.append(f"{key}: Windows has {want}, Theme.swift has {got}")

    print(f"Compared {len(speakers)} speaker hues, 3 clarity colours, 2 ink brushes")
    print(f"          and {len(want_numbers)} numeric rules against the Windows app")

    if failures:
        print("\nFAIL")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("\nOK: the macOS palette matches the Windows one it was copied from.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
