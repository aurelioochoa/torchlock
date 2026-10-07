#!/usr/bin/env python3
"""Validate release contents and iOS 6 package compatibility without dpkg."""
import importlib.util
import io
from pathlib import Path
import plistlib
import struct
import tarfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cydia_index", ROOT / "scripts/cydia-index.py")
index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index)


def contents(path):
    members = dict(index.ar_members(path.read_bytes()))
    assert members["debian-binary"] == b"2.0\n"
    assert "control.tar.gz" in members and "data.tar.gz" in members, "iOS 6 requires gzip archives"
    with tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"]), mode="r:gz") as archive:
        return {item.name.lstrip("./"): archive.extractfile(item).read()
                for item in archive.getmembers() if item.isfile()}


def main():
    version = next(line.split(": ", 1)[1] for line in (ROOT / "tweak/control").read_text().splitlines()
                   if line.startswith("Version: "))
    package = ROOT / f"tweak/packages/com.aurelio.torchlock_{version}_iphoneos-arm.deb"
    assert f"Version: {version}\n" in index.deb_control(package) + "\n"
    files = contents(package)
    dylib_path = "Library/MobileSubstrate/DynamicLibraries/TorchLock.dylib"
    binary = files[dylib_path]
    magic, cpu, subtype, _, count, _, _ = struct.unpack_from("<7I", binary)
    assert (magic, cpu, subtype) == (0xFEEDFACE, 12, 9), "Expected armv7 Mach-O"
    offset = 28
    minimum = None
    for _ in range(count):
        command, size = struct.unpack_from("<2I", binary, offset)
        if command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            minimum = struct.unpack_from("<I", binary, offset + 8)[0]
        offset += size
    assert minimum == 0x60000, "Expected iOS 6.0 deployment target"
    assert b"TorchLockNotificationBar" in binary
    # Positive control: the same detection must find the probe in a debug build.
    debug = max((ROOT / "tweak/packages").glob("*+debug_*.deb"), key=lambda path: path.stat().st_mtime)
    marker = b"com.aurelio.torchlock.test"
    assert marker in contents(debug)[dylib_path], "Debug positive control lacks the test listener"
    assert marker not in binary and b"TorchLockDeviceProbe" not in binary, "Release contains test code"
    preferences = plistlib.loads(files["Library/PreferenceLoader/Preferences/TorchLock/TorchLock.plist"])
    settings = {item["key"]: item for item in preferences["items"] if "key" in item}
    assert settings["ShowInNotificationCenter"]["default"] is False
    position = settings["ButtonPosition"]
    assert position["default"] == "left"
    assert position["validTitles"] == ["Left", "Right"]
    assert position["validValues"] == ["left", "right"]
    assert settings["ReplaceCameraGrabber"]["default"] is False
    icons = settings["IconStyle"]
    assert icons["default"] == "bolt"
    assert icons["validTitles"] == ["Original Bolt", "iOS 6 Classic", "Metal", "Outline", "Light Bulb"]
    assert icons["validValues"] == ["bolt", "classic", "metal", "outline", "bulb"]
    assert b"ReplaceCameraGrabber" in binary and b"IconStyle" in binary
    assert b"handleCameraTapGesture:" in binary
    for setting in settings.values():
        assert setting["PostNotification"] == "com.aurelio.torchlock/prefs-changed"
    print(f"RELEASE PACKAGE CHECK PASSED: {package.name}")


if __name__ == "__main__":
    main()
