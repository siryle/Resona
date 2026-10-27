#!/usr/bin/env python3
"""Verify and publish immutable versioned artifacts from CI."""
import argparse
import hashlib
import json
import os
import plistlib
import struct
import tarfile
import subprocess
import sys
import tempfile
import shutil
import urllib.error
import zipfile
from pathlib import Path
from version import ROOT, stem, version, ios_source_digest, macos_source_digest


def verify_checksum(path):
    expected = hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name
    if path.with_suffix(path.suffix + ".sha256").read_text().strip() != expected:
        raise ValueError("SHA-256 mismatch: " + path.name)


def verify_ipa(path):
    v = version()
    verify_checksum(path)
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if any("_CodeSignature/" in name or name.endswith("embedded.mobileprovision") for name in names):
            raise ValueError("IPA must be unsigned and contain no provisioning profile")
        info = plistlib.loads(archive.read("Payload/Resona.app/Info.plist"))
        if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (v["version"], str(v["build"])):
            raise ValueError("Bundled iOS version differs from VERSION.json")
        if info["CFBundleSupportedPlatforms"] != ["iPhoneOS"]:
            raise ValueError("IPA is not a device build")
        if info.get("UIDeviceFamily") != [1] or info.get("UISupportedInterfaceOrientations") != ["UIInterfaceOrientationPortrait"]:
            raise ValueError("IPA must target iPhone in portrait orientation")
        if "UISupportedInterfaceOrientations~ipad" in info:
            raise ValueError("Unexpected iPad orientation configuration")
        if info.get("ResonaSourceSHA256") != ios_source_digest():
            raise ValueError("IPA source digest differs from committed iOS source; rebuild the IPA")
        binary = archive.read("Payload/Resona.app/Resona")
    magic, cpu = struct.unpack_from("<II", binary)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise ValueError("Expected an arm64 Mach-O executable")
    count = struct.unpack_from("<I", binary, 16)[0]
    offset = 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", binary, offset)
        if command == 0x1D:
            raise ValueError("Unexpected Mach-O code signature")
        if size < 8 or offset + size > len(binary):
            raise ValueError("Invalid Mach-O load command")
        offset += size


def verify_server(path, arch):
    verify_checksum(path)
    with tarfile.open(path, "r:gz") as archive:
        if json.load(archive.extractfile("VERSION.json")) != version():
            raise ValueError("Bundled server version mismatch")
        binary = archive.extractfile("resona").read()
    if binary[:4] != b"\x7fELF" or struct.unpack_from("<H", binary, 18)[0] != {"amd64": 62, "arm64": 183}[arch]:
        raise ValueError("Server executable architecture mismatch")
    if (ROOT / "VERSION.json").read_bytes() not in binary:
        raise ValueError("Server executable does not embed the expected version")


def verify_macos_bundle(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (version()["version"], str(version()["build"])):
        raise ValueError("Bundled macOS version differs from VERSION.json")
    if info.get("ResonaSourceSHA256") != macos_source_digest():
        raise ValueError("macOS source digest differs from committed source; rebuild the app")
    if not (app / "Contents/_CodeSignature/CodeResources").is_file():
        raise ValueError("macOS app must include its ad-hoc signature")
    binary = (app / "Contents/MacOS/Resona").read_bytes()
    magic, count = struct.unpack_from(">II", binary)
    if magic != 0xCAFEBABE or count != 2:
        raise ValueError("Expected a universal macOS executable")
    cpus = set()
    for index in range(count):
        cpu, _, offset, size, _ = struct.unpack_from(">IIIII", binary, 8 + index * 20)
        if offset + size > len(binary) or struct.unpack_from("<II", binary, offset) != (0xFEEDFACF, cpu):
            raise ValueError("Invalid universal Mach-O slice")
        cpus.add(cpu)
    if cpus != {0x01000007, 0x0100000C}:
        raise ValueError("Expected Intel and Apple Silicon macOS slices")


def hfs_image(directory):
    images = []
    for path in directory.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                stream.seek(1024)
                if stream.read(2) in (b"H+", b"HX"):
                    images.append(path)
    if len(images) != 1:
        raise ValueError("Expected one HFS+ partition in the DMG")
    return images[0]


def verify_macos(path):
    verify_checksum(path)
    if path.suffix != ".dmg":
        raise ValueError("macOS release must be a DMG")
    with tempfile.TemporaryDirectory(prefix="resona-dmg-") as directory:
        root = Path(directory)
        if sys.platform == "darwin":
            mount = root / "mounted"
            subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(path)],
                           check=True, capture_output=True)
            try:
                verify_macos_bundle(mount / "Resona.app")
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(mount / "Resona.app")], check=True)
            finally:
                subprocess.run(["hdiutil", "detach", str(mount)], check=True, capture_output=True)
        else:
            sevenzip = shutil.which("7zz") or shutil.which("7z")
            if not sevenzip:
                raise RuntimeError("7-Zip is required to verify the DMG on Linux")
            extracted = root / "extracted"
            # Force two stages: auto-recursion and HFS partition names vary across 7-Zip versions.
            subprocess.run([sevenzip, "x", "-y", "-tDmg", "-o" + str(extracted), str(path)], check=True)
            # The install shortcut points outside the image and is not needed to verify the app.
            subprocess.run([sevenzip, "x", "-y", "-tHFS", "-xr!Applications", "-o" + str(root / "volume"), str(hfs_image(extracted))],
                           check=True)
            apps = list((root / "volume").rglob("Resona.app"))
            if len(apps) != 1:
                raise ValueError("Expected one Resona.app in the DMG")
            verify_macos_bundle(apps[0])


class GitHub:
    def __init__(self, repository):
        self.repository = repository
        self.base = "repos/" + repository

    def request(self, method, path, data=None):
        command = ["gh", "api", "--method", method, self.base + path]
        if data is not None:
            command += ["--input", "-"]
        result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                                text=True, capture_output=True)
        if result.returncode:
            if "(HTTP 404)" in result.stderr:
                raise urllib.error.HTTPError(path, 404, result.stderr, None, None)
            raise RuntimeError(result.stderr.strip())
        return json.loads(result.stdout) if result.stdout else None

    def upload(self, release_id, path):
        from urllib.parse import quote
        url = f"https://uploads.github.com/{self.base}/releases/{release_id}/assets?name=" + quote(path.name)
        return json.loads(subprocess.check_output(
            ["gh", "api", "--method", "POST", url, "-H", "Content-Type: application/octet-stream",
             "--input", str(path)], text=True))

    def verify(self, asset, path):
        with tempfile.TemporaryFile() as output:
            subprocess.run(["gh", "api", f"{self.base}/releases/assets/{asset['id']}",
                            "-H", "Accept: application/octet-stream"], stdout=output, check=True)
            output.seek(0)
            digest = hashlib.sha256()
            while chunk := output.read(1024 * 1024):
                digest.update(chunk)
            if digest.digest() != hashlib.sha256(path.read_bytes()).digest():
                raise RuntimeError("Published asset differs; bump VERSION.json: " + path.name)


def get_release(api):
    try:
        return api.request("GET", "/releases/tags/v" + stem())
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        return None


def prepare(api, commit, ref_type, ref_name, publish_release=True):
    tag = "v" + stem()
    if ref_type == "tag" and ref_name != tag:
        raise ValueError("Release tag differs from VERSION.json: " + ref_name)
    release = get_release(api) if publish_release else None
    published = release is not None and not release["draft"]
    if published and release["target_commitish"] != commit:
        raise RuntimeError("Version was already published from another commit; bump VERSION.json")
    return {"tag": tag, "version": version()["version"], "build": str(version()["build"]), "stem": stem(),
            "image": "ghcr.io/" + api.repository.lower(),
            "published": str(published).lower()}


def verify_docker(path):
    with tarfile.open(path, "r:gz") as archive:
        manifest = json.load(archive.extractfile("manifest.json"))
        if len(manifest) != 1:
            raise ValueError("Expected one Docker image per architecture archive")
        config = json.load(archive.extractfile(manifest[0]["Config"]))
    arch = path.name.removesuffix(".tar.gz").rsplit("-", 1)[1]
    if config["os"] != "linux" or config["architecture"] != arch:
        raise ValueError("Docker image architecture mismatch")
    labels = config["config"]["Labels"]
    if labels.get("org.opencontainers.image.version") != version()["version"] or labels.get("io.resona.build") != str(version()["build"]):
        raise ValueError("Docker image version differs from VERSION.json")
    if labels.get("org.opencontainers.image.revision") != os.environ["GITHUB_SHA"]:
        raise ValueError("Docker image source commit mismatch")


def verify_windows(path):
    verify_checksum(path)
    binary = path.read_bytes()
    if path.suffix != '.exe' or len(binary) < 64 or binary[:2] != b'MZ':
        raise ValueError('Windows release must be an EXE installer')
    offset = struct.unpack_from('<I', binary, 0x3C)[0]
    if offset < 64 or offset + 6 > len(binary) or binary[offset:offset + 4] != b'PE\0\0':
        raise ValueError('Invalid Windows PE header')
    if struct.unpack_from('<H', binary, offset + 4)[0] != 0x8664:
        raise ValueError('Windows installer must be x64')
    v = version()
    if f'{v["version"]}.{v["build"]}'.encode('utf-16le') not in binary:
        raise ValueError('Windows installer version differs from VERSION.json')


def verify_all(directory, image_reference=False):
    ipa = directory / f"Resona-iOS-{stem()}-unsigned.ipa"
    macos = directory / f"Resona-macOS-{stem()}-universal.dmg"
    windows = directory / f"Resona-Windows-{stem()}-x64.exe"
    android = list(directory.glob(f"Resona-Android-{stem()}*.apk"))
    if len(android) != 1 or android[0].name not in (
        f"Resona-Android-{stem()}.apk", f"Resona-Android-{stem()}-preview.apk"
    ):
        raise ValueError("Expected exactly one signed or preview Android APK")
    servers = [directory / f"Resona-server-{stem()}-linux-{arch}.tar.gz" for arch in ("amd64", "arm64")]
    docker = [directory / f"Resona-Docker-{stem()}-linux-{arch}.tar.gz" for arch in ("amd64", "arm64")]
    files = [ipa, macos, windows, *android, *servers, *docker]
    if image_reference:
        files.append(directory / f"Resona-Docker-{stem()}-images.txt")
    for path in files:
        verify_checksum(path)
    verify_ipa(ipa)
    verify_macos(macos)
    verify_windows(windows)
    for path, arch in zip(servers, ("amd64", "arm64")):
        verify_server(path, arch)
    for path in docker:
        verify_docker(path)
    return files + [path.with_suffix(path.suffix + ".sha256") for path in files]


def publish(api, commit, files):
    release = get_release(api)
    if release is None:
        release = api.request("POST", "/releases", {
            "tag_name": "v" + stem(), "target_commitish": commit,
            "name": "Resona " + stem(), "draft": True,
            "generate_release_notes": True,
            "body": "Built and verified by GitHub Actions from VERSION.json.\n\n"
                    "- iOS 17+: unsigned arm64 IPA; re-sign before installation.\n"
                    "- macOS 14+: universal DMG, ad-hoc signed, not notarized.\n"
                    "- Android 7+: APK; a preview uses a development certificate.\n"
                    "- Windows 10/11: x64 EXE installer; upgrades an existing installation in place.\n"
                    "- Linux server archives and Docker load archives: amd64 and arm64.\n"
                    f"- Docker: `ghcr.io/{api.repository.lower()}:v{stem()}`; "
                    "the exact registry digest is in the Docker images.txt attachment.\n"
                    "- Every attachment has a SHA-256 checksum.\n",
        })
    if not release["draft"] and release["target_commitish"] != commit:
        raise RuntimeError("Version was already published from another commit; bump VERSION.json")
    assets = api.request("GET", f"/releases/{release['id']}/assets?per_page=100")
    for path in files:
        matches = [asset for asset in assets if asset["name"] == path.name]
        if len(matches) > 1:
            raise RuntimeError("Duplicate release assets: " + path.name)
        if matches:
            asset = matches[0]
            try:
                api.verify(asset, path)
                continue
            except RuntimeError:
                if not release["draft"]:
                    raise
                api.request("DELETE", f"/releases/assets/{asset['id']}")
        elif not release["draft"]:
            raise RuntimeError("Refusing to change a published release; bump VERSION.json")
        asset = api.upload(release["id"], path)
        api.verify(asset, path)
        print("Verified:", path.name, flush=True)
    if release["draft"]:
        release = api.request("PATCH", f"/releases/{release['id']}", {"draft": False})
    print("Release:", release["html_url"], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--verify-only", action="store_true")
    parser.add_argument("--directory", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    if args.prepare:
        api = GitHub(os.environ["GITHUB_REPOSITORY"])
        outputs = prepare(api, os.environ["GITHUB_SHA"], os.environ["GITHUB_REF_TYPE"], os.environ["GITHUB_REF_NAME"],
                          publish_release=os.environ["GITHUB_EVENT_NAME"] != "pull_request")
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for key, value in outputs.items():
                output.write(f"{key}={value}\n")
        return
    files = verify_all(args.directory, image_reference=not args.verify_only)
    if args.verify_only:
        print("Verified all package versions, source digests, architectures and SHA-256 checksums")
        return
    publish(GitHub(os.environ["GITHUB_REPOSITORY"]), os.environ["GITHUB_SHA"], files)


if __name__ == "__main__":
    main()
