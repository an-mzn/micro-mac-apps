#!/bin/bash
set -eu
cd "$(dirname "$0")"
folder="$HOME/Library/Application Support/KeyboardPower"
agent="$HOME/Library/LaunchAgents/com.ayan.keyboard-power.plist"
mkdir -p "$folder" "$(dirname "$agent")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
swiftc -O KeyboardPower.swift -o "$tmp/keyboard-power" -framework IOKit -framework AppKit
if [ -f "$agent" ]; then
  launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null || true
fi
cp "$tmp/keyboard-power" "$folder/keyboard-power"
/usr/libexec/PlistBuddy -c 'Clear dict' "$tmp/agent.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :Label string com.ayan.keyboard-power' "$tmp/agent.plist"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$tmp/agent.plist"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $folder/keyboard-power" "$tmp/agent.plist"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$tmp/agent.plist"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$tmp/agent.plist"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $folder/output.log" "$tmp/agent.plist"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $folder/error.log" "$tmp/agent.plist"
cp "$tmp/agent.plist" "$agent"
launchctl bootstrap "gui/$(id -u)" "$agent"
echo 'Keyboard Power installed.'
