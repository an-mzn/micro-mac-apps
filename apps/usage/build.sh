#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
out="${1:-$PWD/dist}"
mkdir -p "$out"
staging="$(mktemp -d "$out/.codex-usage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Codex Usage.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
install -m 755 "$bin_dir/CodexUsage" "$app/Contents/MacOS/CodexUsage"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$staging/Codex Usage.zip"
mkdir "$staging/extracted"
ditto -x -k "$staging/Codex Usage.zip" "$staging/extracted"
codesign --verify --strict "$staging/extracted/Codex Usage.app"
if [[ -e "$out/Codex Usage.app" ]]; then
    rm -rf "$out/Codex Usage.app"
fi
mv "$app" "$out/Codex Usage.app"
mv -f "$staging/Codex Usage.zip" "$out/Codex Usage.zip"
printf '%s\n' "$out/Codex Usage.zip"
