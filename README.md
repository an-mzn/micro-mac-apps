# Corner Match

Corner Match changes InDesign's actual macOS window shape and shadow to match the four corner radii reported by a native AppKit window. It runs inside InDesign through Adobe's ExtendScript `ExternalObject` mechanism. It uses no screenshots, overlay windows, or polling timers.

Native support currently covers **InDesign only**. The application list retains other choices, but shows them as unsupported until an adapter is implemented. There is no overlay fallback.

## Build

Requires macOS 26 or later and Xcode or the Xcode Command Line Tools. The current implementation has been tested on macOS 27 with InDesign 2027 on Apple silicon.

```sh
./build.sh
open 'build/Corner Match.app'
```

Set `CODESIGN_IDENTITY` to a development signing identity, or put the identity in the ignored local file `build/signing-identity`. Otherwise builds are ad-hoc signed. The build includes a native bundle in the app's Resources directory. The app is not notarized.

## Use

1. Open InDesign, then open Corner Match and press **Apply**. If requested, allow Corner Match to control InDesign under System Settings → Privacy & Security → Automation.
2. Leave **Apply automatically when InDesign opens** enabled to install a small script in InDesign's per-user `Scripts/Startup Scripts` folder. It loads the native bundle from the current Corner Match app location. Keep the app at that location, or reapply after moving it.
3. Quit Corner Match whenever you like. The extension lives inside InDesign and keeps the corners applied until InDesign quits.
4. Press **Restore originals** to restore the original radii and remove the managed startup script. Do this before deleting Corner Match.

No Screen Recording or Accessibility permission is required for this implementation. No Adobe application files or documents are modified. SIP remains enabled. The extension uses private macOS window APIs, which may change in future macOS versions; it is experimental software, not a supported Adobe or Apple feature.

If you rebuild the native bundle, restart InDesign after saving your documents so it can load the new native code. The build replaces executables atomically to avoid overwriting code already loaded by running processes.

## How it works

Adobe's documented [ExternalObject API](https://extendscript.docsforadobe.dev/integrating-external-libraries/externalobject-object/) loads a native bundle into an InDesign scripting engine. The extension samples an unshown AppKit window at the target window’s actual frame, preserving the system’s separate top and bottom radii, applies it through private AppKit and WindowServer APIs, and listens for window activation, resize and full-screen events. It restores the recorded four original radii when disabled. Full-screen windows use square corners.

The native extension does not need the menu-bar utility running after application. There is no continuous screen capture, image buffer, overlay compositor, or app-side tracking loop. No claim of zero battery impact or complete absence of leaks is made.

## Verification

The native window test exercises 20 floating → display-filling → floating → restore cycles. It compares all four radii against independent native AppKit windows and checks restoration of deliberately asymmetric originals. On the tested built-in display, the display-filling reference resolves to 16-point top corners and approximately 32.459-point bottom corners. These values are sampled at runtime, not hardcoded. Geometry samples are cached with a 64-entry limit and invalidated when display parameters change; there is no polling or continuous rendering.

The per-corner extension was also loaded by a clean InDesign restart with the utility closed and its display-filling shape inspected. Earlier live tests verified startup with the utility closed and Restore/Apply controls, and closed a temporary document without saving.

Apple's `leaks` tool reported zero leaks after the 20-cycle native test, while also warning of restricted process debugging. This is evidence from that run, not proof that every leak is absent.

Run the native window test locally:

```sh
mkdir -p build
clang -fobjc-arc Tests/NativeWindowTests.m -o build/native-window-tests -framework AppKit
build/native-window-tests
```

## Licence

[MIT](LICENSE)
