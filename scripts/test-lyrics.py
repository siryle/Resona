#!/usr/bin/env python3
import subprocess
from version import ROOT

out = ROOT / ".build/lyrics-tests"
out.parent.mkdir(exist_ok=True)
subprocess.run(["swiftc", str(ROOT / "ios/Resona/Lyrics.swift"),
                str(ROOT / "ios/Tests/LyricsTests.swift"), "-o", str(out)], check=True)
subprocess.run([str(out)], check=True)
