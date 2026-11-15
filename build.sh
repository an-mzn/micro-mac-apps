#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app='build/Corner Match.app'
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
swiftc -parse-as-library -O Sources/main.swift -o "$app/Contents/MacOS/CornerMatch" \
  -framework AppKit -framework SwiftUI -framework CoreGraphics \
  -framework ServiceManagement -framework ScreenCaptureKit
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
