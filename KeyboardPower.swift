import Foundation
import AppKit
import IOKit.ps
import Darwin

@objc protocol BrightnessClient {
    @objc(copyPropertyForKey:keyboardID:) func get(_ key: String, id: UInt64) -> Any?
    @objc(setProperty:withKey:keyboardID:) func set(_ value: Any, key: String, id: UInt64) -> Bool
}
@objc protocol KeyboardClient {
    func copyKeyboardBacklightIDs() -> [NSNumber]?
    @objc(isKeyboardBuiltIn:) func built(_ id: UInt64) -> Bool
    @objc(isAutoBrightnessEnabledForKeyboard:) func auto(_ id: UInt64) -> Bool
    @objc(enableAutoBrightness:forKeyboard:) func setAuto(_ value: Bool, id: UInt64) -> Bool
}
let stateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KeyboardPower/original.plist")
let key = "KeyboardBacklightBrightness"
guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
      let bc = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
      let kc = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { fputs("CoreBrightness unavailable\n", stderr); exit(1) }
let bo = bc.init(), ko = kc.init()
let b = unsafeBitCast(bo, to: BrightnessClient.self), k = unsafeBitCast(ko, to: KeyboardClient.self)
guard let id = k.copyKeyboardBacklightIDs()?.first(where: { k.built($0.uint64Value) })?.uint64Value,
      b.get(key, id: id) != nil else { fputs("No built-in backlight found\n", stderr); exit(1) }
if CommandLine.arguments.contains("--status") {
    print("brightness=\(b.get(key, id: id) ?? "unknown") auto=\(k.auto(id))")
    exit(0)
}
if CommandLine.arguments.contains("--restore") {
    if let state = NSDictionary(contentsOf: stateURL), let original = state["auto"] as? Bool {
        guard k.setAuto(original, id: id), k.auto(id) == original else { fputs("Could not restore automatic brightness\n", stderr); exit(1) }
        print("Restored automatic keyboard brightness: \(original)")
    }
    exit(0)
}
let lockPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KeyboardPower/instance.lock").path
let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { fputs("Already running or lock unavailable\n", stderr); exit(0) }
if !FileManager.default.fileExists(atPath: stateURL.path) {
    guard (NSDictionary(dictionary: ["auto": k.auto(id)])).write(to: stateURL, atomically: true) else { fputs("Cannot save original setting\n", stderr); exit(1) }
}
func apply() {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { fputs("Cannot read power source\n", stderr); return }
    let target: Float
    if source == kIOPSACPowerValue { target = 0.90 }
    else if source == kIOPSBatteryPowerValue { target = 0.15 }
    else { fputs("Unknown power source: \(source)\n", stderr); return }
    if k.auto(id) && (!k.setAuto(false, id: id) || k.auto(id)) { fputs("Could not disable keyboard auto brightness\n", stderr); return }
    guard b.set(NSNumber(value: target), key: key, id: id) else { fputs("Brightness write failed\n", stderr); return }
    print("Applied \(target) for \(source)"); fflush(stdout)
}
let handler: () -> Void = apply
let context = Unmanaged.passRetained(handler as AnyObject).toOpaque()
let callback: IOPowerSourceCallbackType = { pointer in
    guard let pointer = pointer else { return }
    let handler = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as! () -> Void
    handler()
}
guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { fputs("Cannot subscribe to power events\n", stderr); exit(1) }
CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in apply() }
apply()
CFRunLoopRun()
withExtendedLifetime(wakeObserver) {}
