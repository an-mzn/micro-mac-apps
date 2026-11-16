# FocusBar

A small native macOS menu bar app for keeping your current focus in view.

Click the menu bar item to edit your focus beneath the menu bar. Press Return or click away to save. Your text can be up to 30 characters and is saved between launches. When the field is blank, only ✦ appears. Right-click the item and choose **Quit FocusBar** to quit.

## Build and run

Requires macOS 12 or later and Xcode or the Xcode Command Line Tools.

```sh
./scripts/build.sh
open build/FocusBar.app
```

To keep the app, copy `build/FocusBar.app` to Applications. Add it to Login Items in System Settings if you want it to start automatically.

FocusBar uses AppKit and does no scheduled background work. Like any running app, it uses some memory and a small amount of system resources.
