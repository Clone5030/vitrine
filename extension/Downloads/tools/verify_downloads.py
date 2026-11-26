#!/usr/bin/env python3
"""Verify Downloads injection and all guarded executable patches in a built IPA."""
import json
import plistlib
import struct
import sys
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile

from patch_native_restrictions import UUID, SETTER, CAVE, ORIGINAL, branch, layout, trampoline
from patch_key_request_mode import CALL_SITE, WINDOW, ORIGINAL as KEY_ORIGINAL
from patch_native_trace import POINTS, trampoline as trace_trampoline

COMPANION = "SpotifyAudioProbe.dylib"


def load_paths(binary):
    cursor = 32
    paths = []
    for _ in range(struct.unpack_from("<I", binary, 16)[0]):
        command, length = struct.unpack_from("<II", binary, cursor)
        if length < 8 or cursor + length > len(binary):
            raise ValueError("Invalid Mach-O load command")
        if command & 0x7fffffff in (0xc, 0x18, 0x1f, 0x23):
            if length < 24:
                raise ValueError("Invalid dylib load command")
            name = struct.unpack_from("<I", binary, cursor + 8)[0]
            if not 24 <= name < length:
                raise ValueError("Invalid dylib load path")
            paths.append(binary[cursor + name:cursor + length].split(b"\0")[0].decode())
        cursor += length
    return paths


def verify_native(binary):
    _, _, segments, uuid = layout(binary)
    if uuid != UUID:
        raise ValueError("Downloads executable UUID does not match the verified Spotify build")

    def check(address, expected, label):
        for name, vm, _, fileoff, filesize, _ in segments:
            if name == b"__TEXT" and vm <= address and address + len(expected) <= vm + filesize:
                offset = fileoff + address - vm
                if binary[offset:offset + len(expected)] == expected:
                    return
                break
        raise ValueError("Missing or changed Downloads patch: " + label)

    check(SETTER, struct.pack("<I", branch(SETTER, CAVE)) + ORIGINAL[4:], "offline restrictions entry")
    check(CAVE, trampoline(), "offline restrictions trampoline")
    check(WINDOW, KEY_ORIGINAL[:CALL_SITE - WINDOW], "key request setup")
    check(CALL_SITE + 4, KEY_ORIGINAL[CALL_SITE - WINDOW + 4:], "original key call")
    for point in POINTS:
        name, address, cave, expected, _ = point
        entry = struct.pack("<I", branch(address, cave)) + expected[4:]
        check(address, entry, "key " + name.lower() + " entry")
        check(cave, trace_trampoline(point), "key " + name.lower() + " trampoline")
    return uuid.hex()


def verify(path):
    with ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate entries in IPA")
        hosts = [name for name in names if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(hosts) != 1:
            raise ValueError("IPA must contain exactly one host app")
        base = hosts[0][:-len("Info.plist")]
        host = plistlib.loads(archive.read(hosts[0]))
        if host.get("CFBundleShortVersionString") != "9.1.90":
            raise ValueError("Downloads requires the verified Spotify 9.1.90 build")
        binary = archive.read(base + host["CFBundleExecutable"])
        uuid = verify_native(binary)
        loads = [p for p in load_paths(binary) if PurePosixPath(p).name == COMPANION]
        if len(loads) != 1:
            raise ValueError("Spotify must load the Downloads companion exactly once")
        companions = [name for name in names if name.startswith(base) and name in (base + COMPANION, base + "Frameworks/" + COMPANION)]
        if len(companions) != 1:
            raise ValueError("Downloads companion is missing or duplicated")
        companion = archive.read(companions[0])
        if companion[:4] != b"\xcf\xfa\xed\xfe" or b"SAPVitrineBridge\0" not in companion:
            raise ValueError("Downloads companion is not the Vitrine bridge library")
        return {"artifact": Path(path).name, "spotify_uuid": uuid,
                "companion": companions[0], "load_path": loads[0],
                "offline_restrictions": "verified", "key_mode_zero": "verified",
                "native_observation": "verified", "verification": "passed"}


if __name__ == "__main__":
    try:
        print(json.dumps(verify(sys.argv[1]), indent=2))
    except (KeyError, ValueError, OSError, BadZipFile, struct.error) as error:
        raise SystemExit("Downloads IPA verification failed: " + str(error))
