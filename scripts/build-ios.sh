#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/prepare-ios.py
python3 scripts/test-lyrics.py
mode="${1:-iphoneos}"
case "$mode" in
  iphoneos) destination="generic/platform=iOS" ;;
  iphonesimulator) destination="generic/platform=iOS Simulator" ;;
  *) echo "Usage: scripts/build-ios.sh [iphoneos|iphonesimulator]" >&2; exit 1 ;;
esac
xcodebuild -project ios/Resona.xcodeproj -scheme Resona \
  -configuration Release -sdk "$mode" -destination "$destination" \
  -derivedDataPath ".build/ios-$mode" CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO build
if [ "$mode" = iphoneos ]; then
  python3 scripts/package-ios.py
fi
