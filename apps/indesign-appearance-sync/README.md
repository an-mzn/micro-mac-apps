# InDesign Appearance Sync

Matches InDesign's **Light** and **Dark** colour themes to the macOS appearance. An ExtendScript startup script loads a small native bundle into InDesign. The bundle listens for macOS appearance notifications, then briefly starts `osascript` to set Adobe's documented `app.generalPreferences.uiBrightnessPreference`. There is no polling, overlay, or always-running helper process. The bundle and observer remain in InDesign while it is open; resource use has not been benchmarked.

This is separate from Corner Match. It only changes InDesign's interface colour theme, not document colours or the pasteboard setting. It does not change when you manually change the InDesign theme until the next macOS appearance event or InDesign launch. macOS or InDesign may request Automation permission. Changes during modal dialogs and future macOS/InDesign updates have not been tested.

## Install

Open InDesign, then run:

```sh
./build.sh
./install.py
```

The startup script references the bundle in this folder; keep the project in place. After moving it, quit and reopen InDesign, then run `./install.py` from its new location. Changes to compiled native code require restarting InDesign. Build with `CODESIGN_IDENTITY` set to a signing identity if desired; otherwise the bundle is ad-hoc signed.

## Disable

With InDesign open, run `./install.py --uninstall`. This removes the managed startup script and stops the observer in the current session. The bundle may remain loaded until InDesign exits. It leaves the last selected InDesign theme in place; you can change it in InDesign preferences.
