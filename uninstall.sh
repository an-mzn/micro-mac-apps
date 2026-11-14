#!/bin/bash
set -eu
agent="$HOME/Library/LaunchAgents/com.ayan.keyboard-power.plist"
folder="$HOME/Library/Application Support/KeyboardPower"
if [ -f "$agent" ]; then
  launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null || true
fi
if [ -x "$folder/keyboard-power" ]; then
  "$folder/keyboard-power" --restore || { echo 'Could not restore the original keyboard auto-brightness setting; files retained for retry.' >&2; exit 1; }
fi
rm -f "$agent"
rm -rf "$folder"
echo 'Keyboard Power removed.'
