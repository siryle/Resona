#!/usr/bin/env python3
"""Read the only product version source."""
import json
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def version():
    data = json.loads((ROOT / "VERSION.json").read_text())
    if not re.fullmatch(r"\d+\.\d+\.\d+", data["version"]):
        raise ValueError("Expected major.minor.patch in VERSION.json")
    if type(data["build"]) is not int or data["build"] < 1:
        raise ValueError("Expected a positive integer build")
    return data


def stem():
    v = version()
    return f'{v["version"]}-{v["build"]}'


def ios_source_digest():
    files = [ROOT / name for name in ("VERSION.json", "LICENSE", "THIRD_PARTY.md")]
    files += [p for p in (ROOT / "ios/Resona").rglob("*") if p.is_file() and p.name != ".DS_Store"]
    files += [ROOT / "ios/Resona.xcodeproj/project.pbxproj",
              ROOT / "ios/Resona.xcodeproj/xcshareddata/xcschemes/Resona.xcscheme"]
    digest = hashlib.sha256()
    for path in sorted(files):
        digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def macos_source_digest():
    files = [ROOT / name for name in ("VERSION.json", "LICENSE", "THIRD_PARTY.md", "scripts/build-macos.py", "scripts/version.py")]
    files += [ROOT / "ios/Resona" / name for name in ("API.swift", "Player.swift", "Lyrics.swift", "Offline.swift")]
    files += [p for p in (ROOT / "macos/Resona").rglob("*") if p.is_file() and p.name != ".DS_Store"]
    files += [ROOT / "ios/Resona/Assets.xcassets/BrandIcon.imageset/BrandIcon.png"]
    digest = hashlib.sha256()
    for path in sorted(files):
        digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


if __name__ == "__main__":
    print(stem())
