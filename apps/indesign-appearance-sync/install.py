#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent
BUNDLE = ROOT / 'build/AppearanceSync.bundle'
MARKER = '// InDesign Appearance Sync — managed startup script'

def run(script):
    apple = 'tell application id "com.adobe.InDesign"\nwith timeout of 15 seconds\ndo script ' + json.dumps(script, ensure_ascii=True) + ' language javascript\nend timeout\nend tell'
    return subprocess.run(['osascript', '-e', apple], text=True, check=True, capture_output=True).stdout.strip()

def running():
    return subprocess.run(['osascript', '-e', 'application id \"com.adobe.InDesign\" is running'], text=True, capture_output=True).stdout.strip() == 'true'

if not running():
    sys.exit('Open InDesign first, then run this installer.')
panel = run('app.scriptPreferences.scriptsFolder.fsName;')
startup = pathlib.Path(panel).parent / 'Startup Scripts' / 'InDesign Appearance Sync.jsx'
base = pathlib.Path.home() / 'Library/Preferences/Adobe InDesign'
if not startup.resolve().is_relative_to(base.resolve()):
    sys.exit('Unexpected InDesign startup folder; nothing changed.')
js = '''#targetengine "AppearanceSync"
(function () {
    var path = %s;
    if ($.global.__appearanceSync && $.global.__appearanceSyncPath !== path) {
        throw Error("Restart InDesign after moving Appearance Sync.");
    }
    if (!$.global.__appearanceSync) {
        $.global.__appearanceSync = new ExternalObject('lib:' + path);
        $.global.__appearanceSyncPath = path;
    }
    $.global.__appearanceSync.appearanceSyncStart();
    return 'enabled';
})();''' % json.dumps(str(BUNDLE), ensure_ascii=True)

if len(sys.argv) == 2 and sys.argv[1] == '--uninstall':
    if startup.exists():
        if not startup.read_text().startswith(MARKER):
            sys.exit('Different startup script found; nothing removed.')
        startup.unlink()
    run('#targetengine "AppearanceSync"\nif ($.global.__appearanceSync) { $.global.__appearanceSync.appearanceSyncStop(); } "disabled";')
    print('Disabled appearance sync and removed its startup script.')
elif len(sys.argv) == 1:
    if not BUNDLE.is_dir(): sys.exit('Build the bundle first using ./build.sh.')
    if startup.exists() and not startup.read_text().startswith(MARKER):
        sys.exit('Different startup script already exists; nothing changed.')
    result = run(js)
    if result != 'enabled': sys.exit('Unable to enable appearance sync: ' + result)
    startup.parent.mkdir(parents=True, exist_ok=True)
    temp = startup.with_suffix('.jsx.tmp')
    temp.write_text(MARKER + '\n' + js + '\n', encoding='utf-8')
    os.replace(temp, startup)
    print('Enabled appearance sync and installed its InDesign startup script.')
else:
    sys.exit('Usage: ./install.py [--uninstall]')
