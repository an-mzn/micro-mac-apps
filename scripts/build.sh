#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/FocusBar.app"
mkdir -p "$app/Contents/MacOS"
cp "$root/Info.plist" "$app/Contents/Info.plist"
swiftc -O -target "$(uname -m)-apple-macosx12.0" "$root/Sources/main.swift" -o "$app/Contents/MacOS/FocusBar" -framework AppKit
codesign --force --sign - "$app"
echo "Built $app"
