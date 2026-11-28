import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if let url = Bundle.main.url(forResource: "UsageDark", withExtension: "icns"),
   let icon = NSImage(contentsOf: url) {
    app.applicationIconImage = icon
}
let delegate = UsageMenu()
app.delegate = delegate
app.run()
