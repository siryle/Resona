#!/usr/bin/env python3
from version import ROOT, version, ios_source_digest

v = version()
destination = ROOT / "ios/Generated/Version.xcconfig"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(
    f'MARKETING_VERSION = {v["version"]}\nCURRENT_PROJECT_VERSION = {v["build"]}\n'
    f'RESONA_SOURCE_SHA256 = {ios_source_digest()}\n'
)
print(destination.relative_to(ROOT))
