#!/usr/bin/env python3
"""Exercise iOS audio routing notifications on an available iPhone simulator."""
import json
import platform
import plistlib
import subprocess
import tempfile
from pathlib import Path
from version import ROOT


def main():
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    simulators = [device for runtime, entries in devices["devices"].items() if ".iOS-" in runtime
                  for device in entries if device["name"].startswith("iPhone")]
    if not simulators:
        raise SystemExit("Install an iOS runtime and create an iPhone simulator before running this test")
    simulator = next((device for device in simulators if device["state"] == "Booted"), simulators[0])
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="resona-audio-routes-") as tmp:
        folder = Path(tmp)
        app = folder / "ResonaAudioRouteTests.app"
        app.mkdir()
        bundle = "app.resona.audio-route-tests"
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle,
            "CFBundleExecutable": "ResonaAudioRouteTests",
            "CFBundleName": "ResonaAudioRouteTests",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "17.0",
            "LSRequiresIPhoneOS": True,
            "UIDeviceFamily": [1],
            "UIBackgroundModes": ["audio"],
            "UILaunchScreen": {},
            "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        }))
        audio = app / "song.mp3"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                        "-t", "60", "-c:a", "libmp3lame", str(audio)], check=True)
        sources = [ROOT / "ios/Resona" / name for name in ("API.swift", "Lyrics.swift", "Offline.swift", "Player.swift")]
        executable = app / "ResonaAudioRouteTests"
        subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5", "-sdk", sdk,
                        "-target", f"{platform.machine()}-apple-ios17.0-simulator", *map(str, sources),
                        str(ROOT / "ios/Tests/AudioRouteTests.swift"), "-o", str(executable)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        boot = simulator["state"] != "Booted"
        try:
            if boot:
                subprocess.run(["xcrun", "simctl", "boot", simulator["udid"]], check=True)
            subprocess.run(["xcrun", "simctl", "bootstatus", simulator["udid"], "-b"], check=True, timeout=120)
            # Audio services need the UIKit application lifecycle on hosted simulators.
            subprocess.run(["xcrun", "simctl", "install", simulator["udid"], str(app)], check=True)
            result = subprocess.run(["xcrun", "simctl", "launch", "--console", "--terminate-running-process",
                                     simulator["udid"], bundle],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
            print(result.stdout, end="")
            if result.returncode or "PASS: iOS music routing," not in result.stdout:
                raise SystemExit("iOS audio-route tests did not complete successfully")
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", simulator["udid"], bundle], capture_output=True)
            if boot:
                subprocess.run(["xcrun", "simctl", "shutdown", simulator["udid"]], check=True)


if __name__ == "__main__":
    main()
