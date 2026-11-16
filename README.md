# FocusBar

A small native macOS menu bar app for keeping your current focus in view.

Click the text in the menu bar and choose **Rename…** to change it. Your text is saved between launches. Choose **Quit FocusBar** to quit. Leaving the field blank resets the text to “Focus”.

## Build and run

Requires macOS 12 or later and Xcode or the Xcode Command Line Tools.

```sh
./scripts/build.sh
open build/FocusBar.app
```

To keep the app, copy `build/FocusBar.app` to Applications. Add it to Login Items in System Settings if you want it to start automatically.

FocusBar uses AppKit and does no scheduled background work. Like any running app, it uses some memory and a small amount of system resources.
