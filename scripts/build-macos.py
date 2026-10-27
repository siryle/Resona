#!/usr/bin/env python3
"""Build an ad-hoc signed universal macOS app using the shared Apple client core."""
import hashlib
import plistlib
import shutil
import subprocess
from version import ROOT, macos_source_digest, stem, version


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    out = ROOT / "artifacts" / f"Resona-macOS-{stem()}-universal.dmg"
    if out.exists():
        raise SystemExit(f"{out.name} already exists; keep it for a retry or bump VERSION.json.")
    build = ROOT / ".build/macos"
    app = build / "Resona.app"
    if app.exists():
        shutil.rmtree(app)
    executable = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    executable.mkdir(parents=True)
    resources.mkdir()
    sources = [ROOT / "ios/Resona" / name for name in ("API.swift", "Player.swift", "Lyrics.swift", "Offline.swift")]
    sources += sorted((ROOT / "macos/Resona").glob("*.swift"))
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    for arch in ("arm64", "x86_64"):
        run("xcrun", "swiftc", "-swift-version", "5", "-O", "-sdk", sdk, "-target", f"{arch}-apple-macos14.0",
            *sources, "-o", build / f"Resona-{arch}")
    run("xcrun", "lipo", "-create", build / "Resona-arm64", build / "Resona-x86_64", "-output", executable / "Resona")
    brand = ROOT / "ios/Resona/Assets.xcassets/BrandIcon.imageset/BrandIcon.png"
    shutil.copy2(brand, resources / "BrandIcon.png")
    for name in ("LICENSE", "THIRD_PARTY.md"):
        shutil.copy2(ROOT / name, resources / name)
    iconset = build / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            run("sips", "-z", size * scale, size * scale, brand, "--out",
                iconset / f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png")
    run("iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns")
    info = plistlib.loads((ROOT / "macos/Resona/Info.plist").read_bytes())
    v = version()
    info.update(CFBundleShortVersionString=v["version"], CFBundleVersion=str(v["build"]),
                ResonaSourceSHA256=macos_source_digest())
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", "--identifier", "app.resona.macos", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    out.parent.mkdir(exist_ok=True)
    staging = build / "dmg"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    run("ditto", app, staging / "Resona.app")
    (staging / "Applications").symlink_to("/Applications")
    run("hdiutil", "create", "-volname", f"Resona {v['version']}", "-srcfolder", staging,
        "-fs", "HFS+", "-format", "UDZO", out)
    run("hdiutil", "verify", out)
    out.with_suffix(".dmg.sha256").write_text(hashlib.sha256(out.read_bytes()).hexdigest() + "  " + out.name + "\n")
    print(out.relative_to(ROOT))


if __name__ == "__main__":
    main()
