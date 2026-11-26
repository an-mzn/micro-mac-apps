import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = UsageMenu()
app.delegate = delegate
app.run()
