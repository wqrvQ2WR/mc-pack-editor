#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="MC팩편집기.app"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/McPackEditor "$APP/Contents/MacOS/McPackEditor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "Done: $(pwd)/$APP"
