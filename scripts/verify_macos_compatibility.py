"""Check native deployment targets, including libraries whose wheel tags are inaccurate."""

from pathlib import Path
import plistlib
import struct
import sys
from zipfile import ZipFile

MAGICS = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xcf\xfa\xed\xfe")


def arm64_minimums(data):
    magic = data[:4]
    if magic in MAGICS[:2]:
        wide = magic[-1] == 0xbf
        count = struct.unpack_from(">I", data, 4)[0]
        for index in range(count):
            pos = 8 + index * (32 if wide else 20)
            cpu = struct.unpack_from(">I", data, pos)[0]
            offset, size = struct.unpack_from(">QQ" if wide else ">II", data, pos + 8)
            if cpu == 0x100000c:
                yield from arm64_minimums(data[offset:offset + size])
    elif magic == MAGICS[2] and struct.unpack_from("<I", data, 4)[0] == 0x100000c:
        count = struct.unpack_from("<I", data, 16)[0]
        pos = 32
        for _ in range(count):
            command, length = struct.unpack_from("<II", data, pos)
            if length < 8:
                raise ValueError("Invalid Mach-O load command")
            if command in (0x24, 0x32):  # LC_VERSION_MIN_MACOSX, LC_BUILD_VERSION
                packed = struct.unpack_from("<I", data, pos + (8 if command == 0x24 else 12))[0]
                yield (packed >> 16, (packed >> 8) & 255, packed & 255)
            pos += length


def check_file(name, data, minimum):
    versions = list(arm64_minimums(data))
    for version in versions:
        if version > minimum:
            raise ValueError(f"{name} requires macOS {'.'.join(map(str, version))}")
    return len(versions)


def verify_app(app):
    with (app / "Contents/Info.plist").open("rb") as source:
        version = plistlib.load(source)["LSMinimumSystemVersion"]
    minimum = tuple(map(int, version.split(".")))
    minimum += (0,) * (3 - len(minimum))
    count = 0
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as source:
            if source.read(4) not in MAGICS:
                continue
        count += check_file(path.relative_to(app), path.read_bytes(), minimum)
    if not count:
        raise ValueError("No native Apple silicon binaries found")
    print(f"Checked {count} native deployment targets against macOS {version}")


if __name__ == "__main__":
    target = Path(sys.argv[1])
    if target.suffix == ".app":
        verify_app(target)
    else:
        # Also supports auditing dependency wheels before selecting their versions.
        for path in sorted(target.glob("*.whl")):
            versions = []
            with ZipFile(path) as wheel:
                for info in wheel.infolist():
                    with wheel.open(info) as member:
                        if member.read(4) not in MAGICS:
                            continue
                    versions.extend(arm64_minimums(wheel.read(info)))
            if versions:
                print(path.name, "minimum macOS", ".".join(map(str, max(versions))))
