#!/usr/bin/env python3
"""Vitrine Downloads: patch Spotify 9.1.90 and build the companion library.

    build_downloads.py <decrypted Spotify.ipa> --out-ipa <patched.ipa> --out-dylib <SpotifyAudioProbe.dylib>

Three guarded edits to the executable (see the patch_*.py files), each checked against the exact bytes of the
9.1.90 binary before anything is written, plus the companion library the tweak talks to. cyan injects the
library afterwards, together with the tweak, so nothing is redirected here: Vitrine's audio pipeline keeps the
AudioToolbox imports it rebinds itself.

Exit status 3 means this is not the Spotify the edits were verified against; the caller builds without Downloads.
"""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from zipfile import ZipFile

from patch_native_restrictions import patch as patch_limits, guard_header, limits_header, layout
from patch_key_request_mode import patch as patch_key_mode, key_header
from patch_native_trace import patch as patch_native_trace, header as native_trace_header

ROOT = Path(__file__).resolve().parents[1]
UUID = bytes.fromhex("fbce22c17e1b3e0d9be866ff9291943e")
UNSUPPORTED = 3
SOURCE_FILES = [
    "ProbeStubs.c", "ProbeStubs.m", "Diagnostics.m", "Localization.m", "OfflineFlags.m", "WireProto.m",
    "OfflineConfig.m", "TrackJournal.m", "NativeErrorLog.m", "PlayerTrace.m", "NativeOffline.m",
    "TrackDownload.m", "TaurusBridge.m", "AlbumMetadata.m", "SupportLog.m", "DownloadCompatibility.m",
    "OfflineDevices.m", "DiagnosticTrace.m", "TracePlatform.m", "NativeKeyTrace.m",
]


def run(*command):
    subprocess.run([str(part) for part in command], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--out-ipa", type=Path, required=True)
    parser.add_argument("--out-dylib", type=Path, required=True)
    args = parser.parse_args()
    source = args.ipa.resolve()
    if not source.is_file():
        parser.error("Input IPA not found")

    for path, expected, what in ((ROOT / "src/NativeRestrictionsPatch.h", guard_header(), "Native restriction"),
                                 (ROOT / "src/OfflineLimits.h", limits_header(), "Offline limits"),
                                 (ROOT / "src/NativeKeyModePatch.h", key_header(), "Native key-mode"),
                                 (ROOT / "src/NativeTracePatch.h", native_trace_header(), "Native trace")):
        if path.read_text() != expected:
            raise RuntimeError(f"{what} header is out of sync with its patch tool")

    with ZipFile(source) as archive:
        app = next((n.split("/")[1] for n in archive.namelist() if n.startswith("Payload/") and n.split("/")[1].endswith(".app")), None)
        if not app:
            raise RuntimeError("No Payload/*.app in the IPA")
        info = plistlib.loads(archive.read(f"Payload/{app}/Info.plist"))
        executable = f"Payload/{app}/" + info["CFBundleExecutable"]
        version = info.get("CFBundleShortVersionString")
        native = archive.read(executable)
        try:
            uuid = layout(native)[3]
        except ValueError as error:
            print(f"downloads: {error}", file=sys.stderr)
            return UNSUPPORTED
    if version != "9.1.90" or uuid != UUID:
        print(f"downloads: Spotify {version} (UUID {uuid.hex() if uuid else '?'}) is not the 9.1.90 build the "
              "download patches were verified against; building without Downloads.", file=sys.stderr)
        return UNSUPPORTED

    patched, limits = patch_limits(native)
    patched, key = patch_key_mode(patched, runtime_selectable=False)
    patched, trace = patch_native_trace(patched)
    key["implementation"] = "verified static observation boundary restores fixed w2=0 before the original indirect call"
    key["configuration_source"] = "verified_static_trace_argument"

    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    args.out_dylib.parent.mkdir(parents=True, exist_ok=True)
    run("xcrun", "--sdk", "iphoneos", "clang", "-dynamiclib", "-arch", "arm64", "-target", "arm64-apple-ios15.0",
        "-isysroot", sdk, "-fobjc-arc", "-std=gnu11", "-O2", "-fvisibility=hidden",
        "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-nullability-completeness",
        "-Werror=implicit-function-declaration", "-I" + str(ROOT / "src"), "-DSAP_ENABLE_WAV_CAPTURE=0",
        *(ROOT / "src" / name for name in SOURCE_FILES),
        "-framework", "AudioToolbox", "-framework", "Foundation", "-framework", "UIKit",
        "-framework", "AVFAudio", "-framework", "CoreGraphics", "-framework", "AVFoundation",
        "-framework", "CoreMedia", "-framework", "Network",
        "-Wl,-install_name,@rpath/SpotifyAudioProbe.dylib", "-o", args.out_dylib)
    if shutil.which("codesign"):
        run("codesign", "--force", "--sign", "-", "--timestamp=none", args.out_dylib)

    args.out_ipa.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(source) as original, ZipFile(args.out_ipa, "w", allowZip64=True) as result:
        for member in original.infolist():
            data = patched if member.filename == executable else original.read(member.filename)
            result.writestr(member, data)
    with ZipFile(args.out_ipa) as check:
        if check.testzip() is not None:
            raise RuntimeError("IPA ZIP integrity check failed")
    print(json.dumps({"output": str(args.out_ipa), "sha256": hashlib.sha256(args.out_ipa.read_bytes()).hexdigest(),
                      "spotify_uuid": UUID.hex(), "native_limits": limits, "key_request_mode": key,
                      "native_observation": trace}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
