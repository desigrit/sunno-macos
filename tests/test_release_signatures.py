"""Reject tampered feeds, archives, keys and signed-but-inconsistent metadata."""

import base64
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from zipfile import ZipFile

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from create_appcast import create_appcast, FEED
from verify_release import verify_release


class ReleaseSignatureTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.archive = Path(temp.name) / "Sunno-1.0.92.0-macOS-arm64.zip"
        self.feed = Path(temp.name) / "appcast.xml"
        self.key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
        with ZipFile(self.archive, "w") as archive:
            archive.writestr("Sunno.app/Contents/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "com.desigrit.sunno", "CFBundleVersion": "5",
                "CFBundleShortVersionString": "1.0.92", "SunnoReleaseVersion": "1.0.92.0",
                "LSMinimumSystemVersion": "13.3", "SUPublicEDKey": self.public,
                "SUFeedURL": FEED, "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
            }))
        signature = base64.b64encode(self.key.sign(self.archive.read_bytes())).decode()
        self.content = create_appcast(self.archive, signature, self.public)
        self.sign_feed(self.content)

    def sign_feed(self, content):
        signature = base64.b64encode(self.key.sign(content)).decode()
        self.feed.write_bytes(content + (
            f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n"
        ).encode())

    def verify(self):
        verify_release(self.archive, self.feed, self.public)

    def test_accepts_matching_signed_release(self):
        self.verify()

    def test_rejects_changed_archive(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"changed")
        with self.assertRaises(InvalidSignature): self.verify()

    def test_rejects_changed_feed(self):
        self.feed.write_bytes(self.feed.read_bytes().replace(b"Sunno", b"Other", 1))
        with self.assertRaises(InvalidSignature): self.verify()

    def test_rejects_wrong_public_key(self):
        self.public = base64.b64encode(Ed25519PrivateKey.generate().public_key().public_bytes(
            Encoding.Raw, PublicFormat.Raw)).decode()
        with self.assertRaises(InvalidSignature): self.verify()

    def test_rejects_missing_trailer_or_extra_unsigned_bytes(self):
        signed = self.feed.read_bytes()
        for content in (self.content, signed + b"modified"):
            self.feed.write_bytes(content)
            with self.assertRaises(ValueError): self.verify()

    def test_rejects_wrong_content_length(self):
        self.feed.write_bytes(self.feed.read_bytes().replace(
            f"length: {len(self.content)}".encode(), b"length: 1"))
        with self.assertRaises(ValueError): self.verify()

    def test_rejects_signed_but_wrong_destination_or_version(self):
        for old, new in [(b"/download/v1.0.92.0/", b"/download/v1.0.93.0/"),
                         (b"<sparkle:version>5<", b"<sparkle:version>6<"),
                         (b">arm64<", b">x86_64<")]:
            with self.subTest(old=old):
                self.sign_feed(self.content.replace(old, new))
                with self.assertRaises(ValueError): self.verify()


if __name__ == "__main__":
    unittest.main()
