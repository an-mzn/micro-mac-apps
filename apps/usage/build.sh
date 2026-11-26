#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
    exit 1
fi
xcodegen generate
xcodebuild -project CodexUsage.xcodeproj -scheme CodexUsage -configuration Release \
    -derivedDataPath .xcodebuild CODE_SIGNING_ALLOWED=NO build
out="${1:-$PWD/dist}"
mkdir -p "$out"
app="$out/Usage.app"
staging="$out/.Usage.app.new"
rm -rf "$staging"
ditto .xcodebuild/Build/Products/Release/CodexUsage.app "$staging"
codesign --force --deep --sign - --entitlements App.entitlements "$staging/Contents/Frameworks/UsageCore.framework"
codesign --force --deep --sign - --entitlements Widget.entitlements \
    "$staging/Contents/PlugIns/CodexUsageWidget.appex/Contents/MacOS/CodexUsageWidget"
codesign --force --sign - --entitlements Widget.entitlements "$staging/Contents/PlugIns/CodexUsageWidget.appex"
codesign --force --deep --sign - --entitlements App.entitlements "$staging"
if [[ -e "$app" ]]; then rm -rf "$app"; fi
mv "$staging" "$app"
if [[ "$out" == "$PWD/dist" && -e "$out/Codex Usage.app" ]]; then
    rm -rf "$out/Codex Usage.app"
fi
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
