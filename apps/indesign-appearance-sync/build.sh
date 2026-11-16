#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bundle="$PWD/build/AppearanceSync.bundle"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/Info.plist"
clang -bundle -fobjc-arc AppearanceSync.m -o "$bundle/Contents/MacOS/AppearanceSync.new" -framework AppKit
mv "$bundle/Contents/MacOS/AppearanceSync.new" "$bundle/Contents/MacOS/AppearanceSync"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$bundle"
codesign --verify --strict "$bundle"
