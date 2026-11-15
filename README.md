# Corner Match

Corner Match is an experimental macOS menu-bar utility that gives InDesign windows visually rounded corners, including when another app is active. The project is a prototype and currently targets InDesign only.

The app draws small, mouse-transparent masks over window corners. It uses ScreenCaptureKit to capture what is behind each corner and places the masks immediately above the InDesign window. Closing the settings window leaves the utility running in the menu bar; it does not appear in the Dock or Command-Tab. An optional launch-at-login setting is available.

## Requirements

- macOS 26 or later; the current prototype has been developed on macOS 27.
- Xcode or the Xcode Command Line Tools to build.
- Screen & System Audio Recording permission, used to capture the area behind the corners.

## Build and run

```sh
./build.sh
open 'build/Corner Match.app'
```

Move the app to Applications before enabling launch at login. On first use, click **Start** and grant Screen Recording permission when requested. macOS may require you to quit and reopen the app after changing the permission. Use the menu-bar icon to reopen settings or quit.

The build is ad-hoc signed and is not notarized. When opening a downloaded build, macOS may require approval in Privacy & Security. Rebuilding can require a fresh permission grant.

## Limitations

- This is a visual approximation: the actual InDesign window shape and hit testing remain unchanged. The curve uses a fixed 16-point approximation measured from Safari and Finder on the development Mac; it does not dynamically adapt to the system's window shape.
- Moving and resizing windows, changing Spaces or displays, overlapping windows, and animated content behind a corner may expose rendering or timing glitches. Full-screen windows are excluded.
- The app has to run in the background for the effect to persist. Battery, GPU, WindowServer impact, launch after a real logout, and long-term stability have not been established. It should not be assumed to have zero resource impact.
- Screen captures are processed locally; the app contains no network code.

## Development and verification

`./build.sh` compiles the Swift source directly and puts the local app in `build/`. No external dependencies are required.

During development, a short test with an InDesign window visible exercised 30 start/stop cycles and verified that the four masks were removed after stopping. Apple's `leaks` tool reported zero leaks in that run but also warned of a debugging restriction; this is not a proof that all leaks are absent. The login item has not been tested across a real logout.

## Licence

[MIT](LICENSE)
