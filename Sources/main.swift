import AppKit
import CoreGraphics
import SwiftUI
import Darwin
import ServiceManagement
import ScreenCaptureKit

// Each capture uses only the region behind one corner. ScreenCaptureKit excludes
// the target and any windows in front of it that overlap that region.
final class CornerView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var corner = 0
    var radius: CGFloat = 16
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        let w = bounds.width, h = bounds.height
        // Continuous curve approximation, aligned with the corner of the target.
        let r = min(radius, w / 1.55, h / 1.55), extent = r * 1.528
        let p = CGMutablePath()
        // Clip out a top-left continuous corner, mirrored for other corners.
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: extent, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: extent), control1: CGPoint(x: extent * 0.36, y: 0), control2: CGPoint(x: 0, y: extent * 0.36))
        p.closeSubpath()
        ctx.saveGState()
        // Local graphics coordinates are bottom-left.
        if corner == 0 || corner == 1 { ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1) }
        if corner == 1 || corner == 3 { ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1) }
        ctx.addPath(p); ctx.clip()
        if corner == 1 || corner == 3 { ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: -w, y: 0) }
        if corner == 0 || corner == 1 { ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: -h) }
        // Captures are drawn into the full small corner rectangle.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }
}
final class MaskWindow: NSWindow {
    let maskView = CornerView()
    init(corner: Int) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 26, height: 26), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        maskView.corner = corner; contentView = maskView
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TrackedWindow {
    let id: CGWindowID
    let masks: [MaskWindow] = (0..<4).map { MaskWindow(corner: $0) }
    var bounds = CGRect.null
    var captureBusy = false
    var lastCapture = Date.distantPast
    var generation = 0
    var hasImage = false
    var lastScene = ""
    init(id: CGWindowID) { self.id = id }
    func hide() { masks.forEach { $0.orderOut(nil) } }
}

final class Controller: NSObject, ObservableObject {
    @Published var enabled = false
    @Published var status = "Ready to test with InDesign."
    private var timer: Timer?
    private var tracked: [CGWindowID: TrackedWindow] = [:]
    private let side: CGFloat = 25
    private var tickInterval: TimeInterval = 0
    private var generation = 0

    func start() {
        guard CGPreflightScreenCaptureAccess() else {
            status = "Allow Screen Recording in System Settings, then reopen Corner Match."
            CGRequestScreenCaptureAccess(); return
        }
        enabled = true
        status = "Waiting for InDesign."
        schedule(interval: 0.2)
        update()
    }
    private func schedule(interval: TimeInterval) {
        guard timer == nil || tickInterval != interval else { return }
        timer?.invalidate(); tickInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
        timer?.tolerance = interval * 0.1
    }
    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        tracked.values.forEach { $0.hide() }; tracked.removeAll()
        enabled = false
        status = "Stopped. InDesign has not been modified."
    }
    func update() {
        guard enabled else { return }
        // Fast tracking while dragging, low-frequency geometry checks at rest.
        let inDesignActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.adobe.InDesign"
        let dragging = inDesignActive && (NSEvent.pressedMouseButtons & 1) != 0
        schedule(interval: dragging ? 0.025 : (tracked.isEmpty ? 1.0 : 0.2))
        guard let primary = NSScreen.screens.first,
              let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let ids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.adobe.InDesign").map { $0.processIdentifier })
        let pid = ProcessInfo.processInfo.processIdentifier
        func bounds(_ d: [String: Any]) -> CGRect? {
            guard let value = d[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: value as CFDictionary)
        }
        let windowIDs = all.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        var active = Set<CGWindowID>()
        for info in all {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, ids.contains(owner),
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let rect = bounds(info), rect.width >= 400, rect.height >= 300 else { continue }
            let frame = NSRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
            if let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.frame, frame) }),
               rect.width >= screen.frame.width - 1 && rect.height >= screen.frame.height - 1 { continue }
            active.insert(number)
            let state: TrackedWindow
            if let existing = tracked[number] { state = existing }
            else { state = TrackedWindow(id: number); tracked[number] = state }
            let moved = state.bounds != rect
            let parts = [CGRect(x: rect.minX, y: rect.minY, width: side, height: side),
                         CGRect(x: rect.maxX-side, y: rect.minY, width: side, height: side),
                         CGRect(x: rect.minX, y: rect.maxY-side, width: side, height: side),
                         CGRect(x: rect.maxX-side, y: rect.maxY-side, width: side, height: side)]
            state.bounds = rect
            let targetIndex = windowIDs.firstIndex(of: number)
            // Only changes behind the target, near a corner, can change its captured background.
            let behind = targetIndex.map { Array(all.dropFirst($0 + 1)) } ?? []
            let scene = behind.compactMap { d -> String? in
                guard let owner = d[kCGWindowOwnerPID as String] as? Int32, owner != pid,
                      let id = d[kCGWindowNumber as String] as? UInt32, let r = bounds(d),
                      parts.contains(where: { $0.intersects(r) }) else { return nil }
                return "\(id):\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
            }.joined(separator: ";")
            let sceneChanged = scene != state.lastScene
            state.lastScene = scene
            let misplaced = state.masks.contains { win in
                guard win.isVisible, let i = windowIDs.firstIndex(of: CGWindowID(win.windowNumber)), let targetIndex else { return true }
                return i >= targetIndex
            }
            for (index, part) in parts.enumerated() {
                let mask = state.masks[index]
                let destination = NSRect(x: part.minX, y: primary.frame.height - part.maxY, width: side, height: side)
                if mask.frame != destination { mask.setFrame(destination, display: false) }
                if state.hasImage && (misplaced || !mask.isVisible) { mask.order(.above, relativeTo: Int(number)) }
            }
            if !state.captureBusy && (moved || sceneChanged || Date().timeIntervalSince(state.lastCapture) > 2.0) {
                state.captureBusy = true
                let token = generation
                let above = Set(all.prefix((targetIndex ?? 0) + 1).compactMap { $0[kCGWindowNumber as String] as? UInt32 })
                Task.detached(priority: .utility) { [weak self, weak state] in
                    var images: [CGImage] = []
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        for part in parts {
                            guard let display = content.displays.first(where: { $0.frame.contains(part) }) else { break }
                            let excludes = content.windows.filter { above.contains($0.windowID) && $0.frame.intersects(part) }
                            let filter = SCContentFilter(display: display, excludingWindows: excludes)
                            let config = SCStreamConfiguration()
                            let scale = CGFloat(CGDisplayPixelsWide(display.displayID)) / display.frame.width
                            config.width = max(1, Int((part.width * scale).rounded()))
                            config.height = max(1, Int((part.height * scale).rounded()))
                            config.sourceRect = part.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                            config.showsCursor = false
                            images.append(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
                        }
                    } catch { images.removeAll() }
                    let capturedImages = images
                    await MainActor.run { [weak self, weak state] in
                        guard let self, let state, self.enabled, self.generation == token,
                              self.tracked[number] === state else { return }
                        state.captureBusy = false; state.lastCapture = Date()
                        guard capturedImages.count == 4 else {
                            state.hasImage = false; state.hide()
                            self.status = "Couldn’t capture a window corner. Check Screen Recording access and display placement."
                            return
                        }
                        for (index, image) in capturedImages.enumerated() { state.masks[index].maskView.image = image }
                        state.hasImage = true
                        for mask in state.masks where !mask.isVisible { mask.order(.above, relativeTo: Int(number)) }
                    }
                }
            }
        }
        for (id, state) in tracked where !active.contains(id) { state.hide(); tracked.removeValue(forKey: id) }
        let nextStatus = active.isEmpty ? "Waiting for an InDesign window." : "Tracking \(active.count) InDesign window\(active.count == 1 ? "" : "s"), even when inactive."
        if status != nextStatus { status = nextStatus }
    }
    deinit { timer?.invalidate() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = Controller()
    private var item: NSStatusItem!
    private var window: NSWindow?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginMessage = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Corner Match")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Corner Match…", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Corner Match", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items { entry.target = self }
        item.menu = menu
        let seen = UserDefaults.standard.bool(forKey: "hasOpenedBefore")
        if !seen || !CGPreflightScreenCaptureAccess() { showWindow() }
        UserDefaults.standard.set(true, forKey: "hasOpenedBefore")
        if CGPreflightScreenCaptureAccess() { model.start() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 310), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Corner Match"; w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: MainView(model: model, app: self))
            w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func quit() { model.stop(); NSApp.terminate(nil) }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = loginEnabled == value ? "" : "Check Login Items in System Settings."
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = "Couldn’t change Login Items: \(error.localizedDescription)"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: Controller
    @ObservedObject var app: AppDelegate
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Corner Match").font(.system(size: 24, weight: .semibold))
            Text("InDesign experiment").font(.headline)
            Text("Round InDesign’s corners while it’s open, including when another app is selected.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.enabled ? "Stop" : "Start") { model.enabled ? model.stop() : model.start() }
                Text(model.status).foregroundStyle(.secondary)
            }
            Toggle("Open automatically at login", isOn: Binding(get: { app.loginEnabled }, set: { app.setLogin($0) }))
            if !app.loginMessage.isEmpty { Text(app.loginMessage).foregroundStyle(.secondary).font(.caption) }
            Divider()
            Text("You can close this window. Corner Match keeps running in the menu bar. Quit it from the menu bar to remove the masks.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 470)
    }
}
@main struct CornerMatch {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
