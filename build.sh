#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app='build/Corner Match.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swift Scripts/generate-icon.swift build/CornerMatch.iconset
iconutil -c icns build/CornerMatch.iconset -o "$app/Contents/Resources/AppIcon.icns"
cp Info.plist "$app/Contents/Info.plist"
swiftc -parse-as-library -O Sources/main.swift -o build/CornerMatch.new \
  -framework AppKit -framework SwiftUI
mv build/CornerMatch.new "$app/Contents/MacOS/CornerMatch"
native="$app/Contents/Resources/CornerMatchNative.bundle"
mkdir -p "$native/Contents/MacOS"
cp Native/Info.plist "$native/Contents/Info.plist"
clang -bundle -fobjc-arc Native/WindowCorners.m -o build/CornerMatchNative.new -framework AppKit
# Replace the inode rather than overwriting code that InDesign may have loaded.
mv build/CornerMatchNative.new "$native/Contents/MacOS/CornerMatchNative"
xattr -cr "$app"
# A persistent development identity helps macOS recognize the app across builds.
# Set CODESIGN_IDENTITY or put an identity in build/signing-identity; otherwise
# the build falls back to ad-hoc signing for machines without a certificate.
identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" && -f build/signing-identity ]]; then
  IFS= read -r identity < build/signing-identity || true
fi
codesign --force --sign "${identity:--}" "$native"
codesign --force --sign "${identity:--}" "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
