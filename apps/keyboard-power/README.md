# Keyboard Power

A user LaunchAgent sets the built-in keyboard backlight to 90% on AC and 15% on battery. It starts at login, listens for IOKit power notifications and reapplies the setting after wake. On AC it sets the keyboard inactivity timeout to Never; on battery it restores the timeout saved before installation. The reported power source does not reliably detect battery discharge while an adapter is connected. It runs without a Dock icon or window.

The installed executable and diagnostic logs are in `~/Library/Application Support/KeyboardPower/`; the LaunchAgent is `~/Library/LaunchAgents/com.ayan.keyboard-power.plist`. The included Swift source can be rebuilt with `swiftc -O KeyboardPower.swift -o keyboard-power -framework IOKit -framework AppKit`.

Run `./install.sh` in Terminal from this directory to compile and install the utility. Xcode Command Line Tools are required. Run `./uninstall.sh` in Terminal to stop and remove the utility and restore the original automatic keyboard brightness and inactivity timeout settings. The current keyboard brightness is not restored. The automatic brightness setting is saved on first installation.

CoreBrightness is an undocumented private framework. Its methods or behavior can change in future macOS releases. The backlight can still turn off during sleep or when the lid is closed, and manual brightness controls can change its value until the next power or wake event. Check the diagnostic logs if it stops working. No administrator privileges or third-party dependencies are required.
