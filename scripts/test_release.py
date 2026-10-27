import tempfile
import unittest
import urllib.error
import hashlib
import io
import plistlib
import struct
import tarfile
import json
import zipfile
from pathlib import Path
from unittest.mock import patch
import release


class FakeGitHub:
    def __init__(self, draft, exists=True, has_asset=False, matches=True):
        self.repository = "Owner/Resona"
        self.release = {"id": 1, "draft": draft, "html_url": "https://example.invalid/release", "target_commitish": "commit"}
        self.exists, self.has_asset, self.matches = exists, has_asset, matches
        self.writes = []

    def request(self, method, path, data=None):
        if method == "GET" and "/tags/" in path:
            if not self.exists:
                raise urllib.error.HTTPError(path, 404, "not found", None, None)
            return self.release
        if method == "GET":
            return [{"name": "test.ipa", "id": 2}] if self.has_asset else []
        self.writes.append((method, path, data))
        self.release.update(data if method == "PATCH" else {})
        return self.release

    def upload(self, release_id, path):
        self.writes.append(("UPLOAD", path.name))
        return {"name": path.name, "id": 3}

    def verify(self, asset, path):
        if not self.matches and asset["id"] == 2:
            raise RuntimeError("different published bytes")


class ReleaseTests(unittest.TestCase):
    def test_prepare_skips_published_version_and_rejects_changed_commit_or_tag(self):
        api = FakeGitHub(False)
        outputs = release.prepare(api, "commit", "tag", "v" + release.stem())
        self.assertEqual(outputs["published"], "true")
        self.assertEqual(outputs["image"], "ghcr.io/owner/resona")
        with self.assertRaisesRegex(RuntimeError, "another commit"):
            release.prepare(api, "different", "tag", "v" + release.stem())
        with self.assertRaisesRegex(ValueError, "differs from VERSION.json"):
            release.prepare(api, "commit", "tag", "v0.0.0-1")
        self.assertEqual(api.writes, [])

    def test_prepare_builds_pull_requests_without_modifying_published_release(self):
        api = FakeGitHub(False)
        outputs = release.prepare(api, "pull-request-commit", "branch", "1/merge", publish_release=False)
        self.assertEqual(outputs["published"], "false")
        self.assertEqual(api.writes, [])

    def test_only_unpublished_draft_assets_can_be_replaced(self):
        api = FakeGitHub(True, has_asset=True, matches=False)
        release.publish(api, "commit", [Path("test.ipa")])
        self.assertEqual([write[0] for write in api.writes], ["DELETE", "UPLOAD", "PATCH"])

    def test_docker_archive_requires_matching_architecture_version_and_source(self):
        labels = {
            "org.opencontainers.image.version": release.version()["version"],
            "io.resona.build": str(release.version()["build"]),
            "org.opencontainers.image.revision": "commit",
        }
        valid = {"os": "linux", "architecture": "arm64", "config": {"Labels": labels}}
        cases = [
            valid,
            dict(valid, architecture="amd64"),
            dict(valid, config={"Labels": dict(labels, **{"io.resona.build": "0"})}),
            dict(valid, config={"Labels": dict(labels, **{"org.opencontainers.image.revision": "different"})}),
        ]
        with tempfile.TemporaryDirectory() as tmp, patch.dict("os.environ", GITHUB_SHA="commit"):
            path = Path(tmp) / f"Resona-Docker-{release.stem()}-linux-arm64.tar.gz"
            for index, config in enumerate(cases):
                with tarfile.open(path, "w:gz") as archive:
                    for name, data in [
                        ("manifest.json", [{"Config": "config.json"}]),
                        ("config.json", config),
                    ]:
                        payload = json.dumps(data).encode()
                        info = tarfile.TarInfo(name)
                        info.size = len(payload)
                        archive.addfile(info, io.BytesIO(payload))
                if index:
                    with self.assertRaises(ValueError):
                        release.verify_docker(path)
                else:
                    release.verify_docker(path)

    def test_hfs_partition_is_found_without_filename_assumptions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "partition-table").write_bytes(bytes(4096))
            with self.assertRaises(ValueError):
                release.hfs_image(root)
            image = root / "4.disk image (Apple_HFS 4)"
            image.write_bytes(bytes(1024) + b"H+" + bytes(1024))
            self.assertEqual(release.hfs_image(root), image)
            (root / "duplicate.hfs").write_bytes(bytes(1024) + b"HX" + bytes(1024))
            with self.assertRaises(ValueError):
                release.hfs_image(root)

    def test_ipa_requires_iphone_portrait_configuration(self):
        info = {
            "CFBundleShortVersionString": release.version()["version"],
            "CFBundleVersion": str(release.version()["build"]),
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "ResonaSourceSHA256": release.ios_source_digest(),
            "UIDeviceFamily": [1],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.ipa"
            for overrides in (
                {},
                {"UIDeviceFamily": [1, 2]},
                {"UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft"]},
                {"UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait"]},
            ):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("Payload/Resona.app/Info.plist", plistlib.dumps(dict(info, **overrides)))
                    archive.writestr("Payload/Resona.app/Resona", struct.pack("<II", 0xFEEDFACF, 0x0100000C) + bytes(24))
                path.with_suffix(".ipa.sha256").write_text(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name)
                if overrides:
                    with self.assertRaises(ValueError):
                        release.verify_ipa(path)
                else:
                    release.verify_ipa(path)

    def test_macos_requires_matching_source_version_and_both_architectures(self):
        info = {
            "CFBundleShortVersionString": release.version()["version"],
            "CFBundleVersion": str(release.version()["build"]),
            "ResonaSourceSHA256": release.macos_source_digest(),
        }
        def package(path, cpus, stamp):
            binary = struct.pack(">II", 0xCAFEBABE, 2)
            binary += b"".join(struct.pack(">IIIII", cpu, 0, 48 + index * 32, 32, 0) for index, cpu in enumerate(cpus))
            binary += b"".join(struct.pack("<II", 0xFEEDFACF, cpu) + bytes(24) for cpu in cpus)
            for directory in ("MacOS", "_CodeSignature"):
                (path / "Contents" / directory).mkdir(parents=True, exist_ok=True)
            (path / "Contents/Info.plist").write_bytes(plistlib.dumps(stamp))
            (path / "Contents/MacOS/Resona").write_bytes(binary)
            (path / "Contents/_CodeSignature/CodeResources").write_text("")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Resona.app"
            package(path, [0x01000007, 0x0100000C], info)
            release.verify_macos_bundle(path)
            package(path, [0x01000007, 0x01000007], info)
            with self.assertRaises(ValueError):
                release.verify_macos_bundle(path)
            package(path, [0x01000007, 0x0100000C], dict(info, ResonaSourceSHA256="stale"))
            with self.assertRaises(ValueError):
                release.verify_macos_bundle(path)
            package(path, [0x01000007, 0x0100000C], dict(info, CFBundleVersion="0"))
            with self.assertRaises(ValueError):
                release.verify_macos_bundle(path)

    def test_published_release_cannot_gain_or_replace_assets(self):
        api = FakeGitHub(False)
        with self.assertRaises(RuntimeError):
            release.publish(api, "commit", [Path("test.ipa")])
        self.assertEqual(api.writes, [])
        api = FakeGitHub(False, has_asset=True, matches=False)
        with self.assertRaises(RuntimeError):
            release.publish(api, "commit", [Path("test.ipa")])
        self.assertEqual(api.writes, [])

    def test_identical_rerun_does_not_modify_release(self):
        api = FakeGitHub(False, has_asset=True)
        release.publish(api, "commit", [Path("test.ipa")])
        self.assertEqual(api.writes, [])

    def test_draft_is_verified_then_published(self):
        api = FakeGitHub(True, exists=False)
        release.publish(api, "commit", [Path("test.ipa")])
        self.assertEqual([w[0] for w in api.writes], ["POST", "UPLOAD", "PATCH"])
        self.assertEqual(api.writes[0][2]["target_commitish"], "commit")
        self.assertFalse(api.release["draft"])

    def test_windows_accepts_inno_bootstrappers_with_the_release_version(self):
        quad = f'{release.version()["version"]}.{release.version()["build"]}'.encode('utf-16le')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'Resona-Windows-test-x64.exe'
            header = bytearray(128)
            header[:2] = b'MZ'
            header[0x3C:0x40] = struct.pack('<I', 128)
            valid = bytes(header) + b'PE\0\0' + struct.pack('<H', 0x8664) + quad
            for binary in (
                valid,
                valid[:132] + struct.pack('<H', 0x14C) + quad,
                b'',
                b'MZ',
                valid[:0x3C] + struct.pack('<I', 0xFFFFFFF0) + valid[0x40:],
                valid[:128] + b'bad!' + valid[132:],
                valid[:132] + struct.pack('<H', 0xAA64) + quad,
                valid[:134] + b'missing-version',
            ):
                path.write_bytes(binary)
                path.with_suffix('.exe.sha256').write_text(
                    hashlib.sha256(binary).hexdigest() + '  ' + path.name)
                if binary in (valid, valid[:132] + struct.pack('<H', 0x14C) + quad):
                    release.verify_windows(path)
                else:
                    with self.assertRaises(ValueError):
                        release.verify_windows(path)

    def test_checksum_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.ipa"
            path.write_bytes(b"content")
            path.with_suffix(".ipa.sha256").write_text("wrong")
            with self.assertRaises(ValueError):
                release.verify_checksum(path)


if __name__ == "__main__":
    unittest.main()
