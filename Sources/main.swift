import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let defaultsKey = "focusText"
    private let defaultText = ""
    private let maximumLength = 30
    private let popover = NSPopover()
    private let field = NSTextField()

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateTitle()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(renameFocus)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        field.frame = NSRect(x: 12, y: 14, width: 236, height: 24)
        field.placeholderString = "Focus"
        field.delegate = self
        field.target = self
        field.action = #selector(finishEditing)
        controller.view.addSubview(field)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    private func updateTitle() {
        let text = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultText
        let title = NSMutableAttributedString(
            string: text,
            attributes: [.baselineOffset: -1]
        )
        title.append(NSAttributedString(string: text.isEmpty ? "✦" : " ✦", attributes: [.baselineOffset: -2]))
        statusItem.button?.attributedTitle = title
    }

    @objc private func renameFocus() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Quit FocusBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        field.stringValue = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultText
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        field.window?.makeKey()
        field.selectText(nil)
    }

    @objc private func finishEditing() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(text, forKey: defaultsKey)
        updateTitle()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.stringValue.count > maximumLength else { return }
        field.stringValue = String(field.stringValue.prefix(maximumLength))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
