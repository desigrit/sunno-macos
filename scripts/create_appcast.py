"""Create the GitHub appcast from the actual packaged app, before Sparkle signs the feed."""

import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile

RELEASES = "https://github.com/desigrit/sunno-macos/releases"
FEED = f"{RELEASES}/latest/download/appcast.xml"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def create_appcast(archive: Path, signature: str, public_key: str) -> bytes:
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid archive signature")
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError("Invalid public verification key")
    with ZipFile(archive) as package:
        info = plistlib.loads(package.read("Sunno.app/Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != "com.desigrit.sunno":
        raise ValueError("This archive is not Sunno")
    if info.get("SUPublicEDKey") != public_key or info.get("SUFeedURL") != FEED:
        raise ValueError("Packaged updater configuration does not match this release")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("The packaged app must verify both feed and archive signatures")
    bundle_version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    version = info.get("SunnoReleaseVersion", bundle_version)
    minimum = info["LSMinimumSystemVersion"]
    for value in (bundle_version, build, minimum):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
            raise ValueError("Release versions must contain only dot-separated numbers")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2,3}", version):
        raise ValueError("Invalid Sunno release version")
    if version != bundle_version and version != bundle_version + ".0":
        raise ValueError("Release version must match the macOS bundle version")
    if archive.name != f"Sunno-{version}-macOS-arm64.zip":
        raise ValueError("Archive filename must match its packaged version")
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Sunno for macOS"
    ET.SubElement(channel, "link").text = RELEASES
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Sunno {version}"
    ET.SubElement(item, "link").text = f"{RELEASES}/tag/v{version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = minimum
    ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "enclosure", {
        "url": f"{RELEASES}/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


if __name__ == "__main__":
    archive, signature, public_key, destination = sys.argv[1:]
    Path(destination).write_bytes(create_appcast(Path(archive), signature, public_key))
