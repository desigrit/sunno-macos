"""Validate release metadata against the ZIP, including mistaken or mismatched artifacts."""
import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("appcast", ROOT / "scripts/create_appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)
KEY = base64.b64encode(bytes(range(32))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / "Sunno-0.3.1-macOS-arm64.zip"
        self.info = {
            "CFBundleIdentifier": "com.desigrit.sunno", "CFBundleVersion": "4",
            "CFBundleShortVersionString": "0.3.1", "LSMinimumSystemVersion": "13.3",
            "SUPublicEDKey": KEY, "SUFeedURL": appcast.FEED,
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
        }

    def generate(self, signature=SIGNATURE):
        with ZipFile(self.archive, "w") as archive:
            archive.writestr("Sunno.app/Contents/Info.plist", plistlib.dumps(self.info))
        return appcast.create_appcast(self.archive, signature, KEY)

    def test_version_destination_size_and_compatibility_come_from_package(self):
        item = ET.fromstring(self.generate()).find("channel/item")
        sparkle = {"s": appcast.SPARKLE}
        self.assertEqual(item.findtext("s:version", namespaces=sparkle), "4")
        self.assertEqual(item.findtext("s:shortVersionString", namespaces=sparkle), "0.3.1")
        self.assertEqual(item.findtext("s:minimumSystemVersion", namespaces=sparkle), "13.3")
        self.assertEqual(item.findtext("s:hardwareRequirements", namespaces=sparkle), "arm64")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.attrib["url"], f"{appcast.RELEASES}/download/v0.3.1/{self.archive.name}")
        self.assertEqual(int(enclosure.attrib["length"]), self.archive.stat().st_size)
        self.assertEqual(enclosure.attrib[f"{{{appcast.SPARKLE}}}edSignature"], SIGNATURE)

    def test_rejects_wrong_identity_key_feed_or_disabled_verification(self):
        for field, value in [
            ("CFBundleIdentifier", "another.app"), ("SUPublicEDKey", "wrong"),
            ("SUFeedURL", "https://example.com/feed"), ("SURequireSignedFeed", False),
            ("SUVerifyUpdateBeforeExtraction", False),
        ]:
            with self.subTest(field=field):
                old = self.info[field]
                self.info[field] = value
                with self.assertRaises(ValueError): self.generate()
                self.info[field] = old

    def test_rejects_version_filename_mismatch_and_invalid_versions(self):
        for field, value in [("CFBundleShortVersionString", "0.3.2"),
                             ("CFBundleVersion", "release-4"),
                             ("LSMinimumSystemVersion", "13&3")]:
            with self.subTest(field=field):
                old = self.info[field]
                self.info[field] = value
                with self.assertRaises(ValueError): self.generate()
                self.info[field] = old

    def test_rejects_missing_or_malformed_signature(self):
        for signature in ("", "!!!", KEY):
            with self.subTest(signature=signature):
                with self.assertRaises(ValueError): self.generate(signature)

    def test_shared_release_version_uses_valid_apple_bundle_version(self):
        self.info.update(CFBundleShortVersionString="1.0.92", CFBundleVersion="5",
                         SunnoReleaseVersion="1.0.92.0")
        self.archive = self.archive.with_name("Sunno-1.0.92.0-macOS-arm64.zip")
        item = ET.fromstring(self.generate()).find("channel/item")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}shortVersionString"), "1.0.92.0")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}version"), "5")
        self.info["SunnoReleaseVersion"] = "1.0.93.0"
        with self.assertRaises(ValueError): self.generate()


if __name__ == "__main__":
    unittest.main()
