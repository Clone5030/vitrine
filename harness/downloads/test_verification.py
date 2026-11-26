"""Package checks use synthetic Mach-O metadata; real patch checks run on the built IPA."""
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "extension/Downloads/tools"))
import verify_downloads as verifier


def executable(load=True):
    command = b""
    if load:
        name = b"@rpath/SpotifyAudioProbe.dylib\0"
        size = (24 + len(name) + 7) & ~7
        command = (struct.pack("<IIIIII", 0xc, size, 24, 0, 0, 0) + name).ljust(size, b"\0")
    return struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, int(load), len(command), 0, 0) + command


class VerificationTests(unittest.TestCase):
    def fixture(self, directory, load=True, companion=True, bridge=True):
        path = Path(directory) / "fixture.ipa"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/Spotify.app/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": "9.1.90", "CFBundleExecutable": "Spotify"}))
            archive.writestr("Payload/Spotify.app/Spotify", executable(load))
            if companion:
                archive.writestr("Payload/Spotify.app/Frameworks/SpotifyAudioProbe.dylib",
                                 b"\xcf\xfa\xed\xfe" + (b"SAPTaurusBridge\0" if bridge else b"other library"))
        return path

    def test_load_command_paths_and_invalid_offsets(self):
        self.assertEqual(verifier.load_paths(executable()), ["@rpath/SpotifyAudioProbe.dylib"])
        bad = bytearray(executable())
        struct.pack_into("<I", bad, 40, len(bad))
        with self.assertRaisesRegex(ValueError, "Invalid dylib load path"):
            verifier.load_paths(bad)

    def test_companion_must_be_loaded_and_have_the_bridge(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(verifier, "verify_native", return_value="verified-by-separate-native-check"):
            self.assertEqual(verifier.verify(self.fixture(directory))["verification"], "passed")
            for options, error in (({"load": False}, "load the Downloads companion"),
                                   ({"companion": False}, "companion is missing"),
                                   ({"bridge": False}, "Taurus bridge library")):
                with self.assertRaisesRegex(ValueError, error):
                    verifier.verify(self.fixture(directory, **options))

    def test_unrecognized_native_uuid_rejected(self):
        binary = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0)
        binary += struct.pack("<II", 0x1b, 24) + b"\0" * 16
        with self.assertRaisesRegex(ValueError, "UUID"):
            verifier.verify_native(binary)


if __name__ == "__main__":
    unittest.main()
