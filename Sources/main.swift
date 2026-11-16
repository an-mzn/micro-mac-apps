import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let defaultsKey = "focusText"
    private let defaultText = "Focus"

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateTitle()
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameFocus), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FocusBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateTitle() {
        statusItem.button?.title = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultText
    }

    @objc private func renameFocus() {
        let alert = NSAlert()
        alert.messageText = "What are you focusing on?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: statusItem.button?.title ?? defaultText)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "Focus"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(text.isEmpty ? defaultText : text, forKey: defaultsKey)
            updateTitle()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
