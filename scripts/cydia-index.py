#!/usr/bin/env python3
"""Build the Cydia/APT index for a flat repository.

    cydia-index.py REPO_DIR            write Packages, Packages.gz, Packages.bz2, Release
    cydia-index.py REPO_DIR --check    exit 1 if those files don't match REPO_DIR/debs

Standard library only, so it runs on a machine without dpkg-scanpackages.
Writes the same flat layout the phone's other working sources use
(`deb <url> ./`): debs under debs/, one Packages stanza per .deb with
MD5/SHA1/SHA256, and an unsigned Release that lists each index's hashes.
"""

import bz2
import gzip
import hashlib
import io
import lzma
import sys
import tarfile
from pathlib import Path

RELEASE_FIELDS = {
    "Origin": "TorchLock",
    "Label": "TorchLock",
    "Suite": "stable",
    "Version": "1.0",
    "Codename": "ios",
    "Architectures": "iphoneos-arm",
    "Components": "main",
    "Description": "TorchLock: instant lock screen flashlight for iOS 6",
}


def ar_members(data):
    if data[:8] != b"!<arch>\n":
        raise ValueError("not an ar archive")
    offset = 8
    while offset < len(data):
        name = data[offset:offset + 16].decode().strip().rstrip("/")
        size = int(data[offset + 48:offset + 58])
        yield name, data[offset + 60:offset + 60 + size]
        offset += 60 + size + (size & 1)


def deb_control(path):
    for name, body in ar_members(path.read_bytes()):
        if not name.startswith("control.tar"):
            continue
        if name.endswith(".xz") or name.endswith(".lzma"):
            body = lzma.decompress(body)
            mode = "r:"
        else:
            mode = "r:*"
        with tarfile.open(fileobj=io.BytesIO(body), mode=mode) as tar:
            for member in tar.getmembers():
                if member.name.lstrip("./") == "control":
                    return tar.extractfile(member).read().decode().strip()
    raise ValueError(f"{path}: no control file")


def build_packages(repo):
    stanzas = []
    for deb in sorted((repo / "debs").glob("*.deb")):
        data = deb.read_bytes()
        stanzas.append("\n".join([
            deb_control(deb),
            f"Filename: debs/{deb.name}",
            f"Size: {len(data)}",
            f"MD5sum: {hashlib.md5(data).hexdigest()}",
            f"SHA1: {hashlib.sha1(data).hexdigest()}",
            f"SHA256: {hashlib.sha256(data).hexdigest()}",
        ]))
    if not stanzas:
        raise SystemExit(f"no .deb files in {repo / 'debs'}")
    return ("\n\n".join(stanzas) + "\n").encode()


def build_release(indexes):
    lines = [f"{key}: {value}" for key, value in RELEASE_FIELDS.items()]
    for algo, header in (("md5", "MD5Sum"), ("sha256", "SHA256")):
        lines.append(f"{header}:")
        for name, data in indexes.items():
            lines.append(f" {hashlib.new(algo, data).hexdigest()} {len(data):>8} {name}")
    return ("\n".join(lines) + "\n").encode()


def build(repo):
    packages = build_packages(repo)
    # mtime=0 and fixed compression keep the output reproducible, so --check
    # compares like with like.
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0, compresslevel=9) as f:
        f.write(packages)
    indexes = {
        "Packages": packages,
        "Packages.gz": gz.getvalue(),
        "Packages.bz2": bz2.compress(packages, 9),
    }
    indexes["Release"] = build_release(indexes)
    return indexes


def main(argv):
    if len(argv) not in (2, 3) or (len(argv) == 3 and argv[2] != "--check"):
        raise SystemExit("usage: cydia-index.py REPO_DIR [--check]")
    repo = Path(argv[1])
    files = build(repo)
    if len(argv) == 3:
        stale = [name for name, data in files.items()
                 if not (repo / name).is_file() or (repo / name).read_bytes() != data]
        if stale:
            print(f"Cydia index out of date: {', '.join(stale)} (run make cydia)", file=sys.stderr)
            return 1
        print(f"Cydia index matches {len(list((repo / 'debs').glob('*.deb')))} package(s)")
        return 0
    for name, data in files.items():
        (repo / name).write_bytes(data)
        print(f"wrote {repo / name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
