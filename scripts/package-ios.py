#!/usr/bin/env python3
"""Package an unsigned device app, verify its version, and record SHA-256."""
import hashlib
import plistlib
import shutil
import subprocess
import zipfile
from version import ROOT, stem, version, ios_source_digest

v = version()
app = ROOT / ".build/ios-iphoneos/Build/Products/Release-iphoneos/Resona.app"
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleShortVersionString"] == v["version"], "App version mismatch"
assert info["CFBundleVersion"] == str(v["build"]), "App build mismatch"
assert info["ResonaSourceSHA256"] == ios_source_digest(), "App source digest mismatch"
assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"], "Not a device build"
assert not (app / "embedded.mobileprovision").exists(), "Unexpected provisioning profile"
signature = app / "_CodeSignature"
if signature.exists():
    shutil.rmtree(signature)
subprocess.run(["codesign", "--remove-signature", str(app / "Resona")], check=True)
assert subprocess.run(["codesign", "--verify", str(app)], capture_output=True).returncode != 0, "App must be unsigned"
out = ROOT / "artifacts" / f"Resona-iOS-{stem()}-unsigned.ipa"
out.parent.mkdir(exist_ok=True)
if out.exists():
    raise SystemExit(f"{out.name} already exists. Keep it for a retry, or bump VERSION.json for a new release.")
for name in ("LICENSE", "THIRD_PARTY.md"):
    shutil.copy2(ROOT / name, app / name)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob("*")):
        if path.is_file():
            archive.write(path, "Payload/Resona.app/" + path.relative_to(app).as_posix())
checksum = hashlib.sha256(out.read_bytes()).hexdigest()
out.with_suffix(out.suffix + ".sha256").write_text(f"{checksum}  {out.name}\n")
print(f"{out.relative_to(ROOT)}\nSHA-256 {checksum}")
