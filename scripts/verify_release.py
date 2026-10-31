"""Verify the exact release bytes with the public key installed in Sunno."""

import base64
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from create_appcast import create_appcast, SPARKLE


def verify_release(archive: Path, feed: Path, public_key: str) -> None:
    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key, validate=True))
    data = feed.read_bytes()
    block = re.search(
        rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?\Z",
        data,
    )
    if block is None:
        raise ValueError("Missing signed appcast trailer")
    content = data[:block.start()]
    if len(content) != int(block[2]):
        raise ValueError("Signed appcast length does not match its contents")
    key.verify(base64.b64decode(block[1], validate=True), content)
    items = ET.fromstring(content).findall("channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one Sunno release")
    enclosure = items[0].find("enclosure")
    if enclosure is None:
        raise ValueError("Missing release archive")
    signature = enclosure.attrib[f"{{{SPARKLE}}}edSignature"]
    key.verify(base64.b64decode(signature, validate=True), archive.read_bytes())
    expected = ET.fromstring(create_appcast(archive, signature, public_key)).find("channel/item")
    if enclosure.attrib != expected.find("enclosure").attrib:
        raise ValueError("Appcast archive URL, length or signature does not match this package")
    for field in ("version", "shortVersionString", "minimumSystemVersion", "hardwareRequirements"):
        tag = f"{{{SPARKLE}}}{field}"
        if items[0].findtext(tag) != expected.findtext(tag):
            raise ValueError(f"Appcast {field} does not match this package")


if __name__ == "__main__":
    verify_release(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
    print("Archive, appcast and packaged public key verified")
