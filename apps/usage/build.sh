#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
    exit 1
fi
signing_identity="${USAGE_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    echo "Set USAGE_SIGNING_IDENTITY to your Apple Development certificate. See README.md." >&2
    exit 1
fi
xcodegen generate
xcodebuild -project Usage.xcodeproj -scheme Usage -configuration Release \
    -derivedDataPath .xcodebuild CODE_SIGNING_ALLOWED=NO build
out="${1:-$PWD/dist}"
mkdir -p "$out"
app="$out/Usage.app"
staging="$out/.Usage.app.new"
rm -rf "$staging"
ditto .xcodebuild/Build/Products/Release/Usage.app "$staging"
codesign --force --deep --sign "$signing_identity" "$staging/Contents/Frameworks/UsageCore.framework"
framework="$staging/Contents/Frameworks/UsageCore.framework"
team_id=$(codesign -dv "$framework" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "The signing certificate must belong to an Apple developer team." >&2
    exit 1
fi
app_group="$team_id.com.an-mzn.codex-usage"
widget="$staging/Contents/PlugIns/UsageWidget.appex"
entitlements_dir=$(mktemp -d)
trap 'rm -r "$entitlements_dir"' EXIT
for name in App Widget; do
    cp "$name.entitlements" "$entitlements_dir/$name.entitlements"
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $app_group" \
        "$entitlements_dir/$name.entitlements"
done
for bundle in "$staging" "$widget"; do
    /usr/libexec/PlistBuddy -c "Add :UsageAppGroup string $app_group" "$bundle/Contents/Info.plist"
done
codesign --force --sign "$signing_identity" --entitlements "$entitlements_dir/Widget.entitlements" "$widget"
codesign --force --sign "$signing_identity" --entitlements "$entitlements_dir/App.entitlements" "$staging"
if [[ -e "$app" ]]; then rm -rf "$app"; fi
mv "$staging" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
printf '%s\n' "$app"
