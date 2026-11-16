import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TargetApp: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var path: String?
    var isEnabled: Bool
    var supportsNative: Bool { id == "com.adobe.InDesign" }
}

enum NativeBridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Native bundles are loaded by Adobe's scripting API. The utility neither
// captures screens nor attempts to change another process's windows directly.
struct InDesignBridge {
    static let identifier = "com.adobe.InDesign"
    static let marker = "// Corner Match native startup — managed by Corner Match"

    static func quoteAppleScript(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func quoteJavaScript(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }
    static func execute(_ javaScript: String) throws -> String {
        guard isRunning else { throw NativeBridgeError.message("Open InDesign, then press Apply.") }
        let source = "with timeout of 10 seconds\ntell application id \"\(identifier)\"\ndo script \(quoteAppleScript(javaScript)) language javascript\nend tell\nend timeout"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if number == -1743 {
                throw NativeBridgeError.message("Allow Corner Match to control InDesign in System Settings → Privacy & Security → Automation, then press Apply.")
            }
            throw NativeBridgeError.message(error[NSAppleScript.errorMessage] as? String ?? "InDesign could not run the native extension.")
        }
        guard let text = result?.stringValue else { throw NativeBridgeError.message("InDesign did not return a result.") }
        return text
    }
    static func enableScript(bundleURL: URL) -> String {
        let path = quoteJavaScript(bundleURL.path)
        return """
        #targetengine "CornerMatchNative"
        (function () {
            var path = \(path);
            if ($.global.__cornerMatchNative && $.global.__cornerMatchNativePath !== path) {
                $.global.__cornerMatchNative.cmDisable();
                $.global.__cornerMatchNative.terminate();
                $.global.__cornerMatchNative = null;
            }
            if (!$.global.__cornerMatchNative) {
                $.global.__cornerMatchNative = new ExternalObject('lib:' + path);
                $.global.__cornerMatchNativePath = path;
            }
            $.global.__cornerMatchNative.cmEnable();
            return 'enabled';
        })();
        """
    }
    static let disableScript = """
    #targetengine "CornerMatchNative"
    (function () {
        if ($.global.__cornerMatchNative) { $.global.__cornerMatchNative.cmDisable(); }
        return 'disabled';
    })();
    """
    static func startupURL() throws -> URL {
        let panelPath = try execute("app.scriptPreferences.scriptsFolder.fsName;")
        let directory = URL(fileURLWithPath: panelPath).deletingLastPathComponent().appendingPathComponent("Startup Scripts", isDirectory: true)
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/Adobe InDesign", isDirectory: true).path + "/"
        guard directory.standardizedFileURL.path.hasPrefix(expected) else {
            throw NativeBridgeError.message("Couldn’t locate InDesign’s per-user startup folder.")
        }
        return directory.appendingPathComponent("Corner Match.jsx")
    }
    static func installStartup(at url: URL, bundleURL: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            guard existing.hasPrefix(marker) else {
                throw NativeBridgeError.message("A different Corner Match.jsx already exists in InDesign’s startup folder.")
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Startup failures must not interrupt Adobe's launch with a modal alert.
        let script = marker + "\n#targetengine \"CornerMatchNative\"\ntry {\n" + enableScript(bundleURL: bundleURL).replacingOccurrences(of: "#targetengine \"CornerMatchNative\"\n", with: "") + "\n} catch (cornerMatchError) { $.writeln('Corner Match: ' + cornerMatchError); }\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
    }
    static func removeStartup(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.hasPrefix(marker) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

final class Controller: NSObject, ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var apps: [TargetApp]
    @Published var status = "Ready to apply native corners."
    @Published private(set) var busy = false
    @Published private(set) var startWithInDesign: Bool
    private let defaults: UserDefaults
    private var startupPaths: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "nativeEnabled")
        startWithInDesign = defaults.object(forKey: "nativeStartWithInDesign") as? Bool ?? true
        startupPaths = defaults.stringArray(forKey: "nativeStartupScripts") ?? []
        if let data = defaults.data(forKey: "targetApplications"), let saved = try? JSONDecoder().decode([TargetApp].self, from: data) {
            apps = saved
        } else {
            let id = InDesignBridge.identifier
            apps = [TargetApp(id: id, name: "Adobe InDesign", path: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path, isEnabled: true)]
        }
        super.init()
    }
    func addApplication(at url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty, id != Bundle.main.bundleIdentifier else { return }
        if let index = apps.firstIndex(where: { $0.id == id }) {
            apps[index].path = url.path
            apps[index].isEnabled = apps[index].supportsNative
        } else {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            apps.append(TargetApp(id: id, name: name, path: url.path, isEnabled: id == InDesignBridge.identifier))
        }
        saveApps()
        if id != InDesignBridge.identifier { status = "Native support is currently available for InDesign. Other apps need their own native adapter." }
        else if enabled { apply() }
    }
    func setApplication(_ id: String, enabled value: Bool) {
        guard let index = apps.firstIndex(where: { $0.id == id }), apps[index].supportsNative else { return }
        apps[index].isEnabled = value
        saveApps()
        if value { apply() } else { stop() }
    }
    func removeApplication(_ id: String) {
        if id == InDesignBridge.identifier { stop() }
        apps.removeAll { $0.id == id }
        saveApps()
    }
    private func saveApps() {
        if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: "targetApplications") }
    }
    private func rememberStartup(_ url: URL) {
        if !startupPaths.contains(url.path) { startupPaths.append(url.path) }
        defaults.set(startupPaths, forKey: "nativeStartupScripts")
    }
    func apply() {
        guard !busy else { return }
        guard apps.contains(where: { $0.id == InDesignBridge.identifier && $0.isEnabled }) else {
            status = "Select InDesign to apply native corners."; return
        }
        guard let bundle = Bundle.main.resourceURL?.appendingPathComponent("CornerMatchNative.bundle"), FileManager.default.fileExists(atPath: bundle.path) else {
            status = "The native extension is missing. Rebuild Corner Match."; return
        }
        busy = true
        defer { busy = false }
        do {
            if startWithInDesign {
                let url = try InDesignBridge.startupURL()
                try InDesignBridge.installStartup(at: url, bundleURL: bundle)
                rememberStartup(url)
            }
            guard try InDesignBridge.execute(InDesignBridge.enableScript(bundleURL: bundle)) == "enabled" else {
                throw NativeBridgeError.message("InDesign did not enable the native extension.")
            }
            enabled = true
            defaults.set(true, forKey: "nativeEnabled")
            status = "Native corners enabled in InDesign. You can quit Corner Match."
        } catch { status = error.localizedDescription }
    }
    func stop() {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if InDesignBridge.isRunning { _ = try InDesignBridge.execute(InDesignBridge.disableScript) }
            for path in startupPaths { try InDesignBridge.removeStartup(at: URL(fileURLWithPath: path)) }
            enabled = false
            defaults.set(false, forKey: "nativeEnabled")
            status = "Original corners restored. Startup script removed."
        } catch { status = error.localizedDescription }
    }
    func setStartup(_ value: Bool) {
        startWithInDesign = value
        defaults.set(value, forKey: "nativeStartWithInDesign")
        if value && enabled { apply() }
        else if !value {
            do {
                for path in startupPaths { try InDesignBridge.removeStartup(at: URL(fileURLWithPath: path)) }
                status = "InDesign won’t load Corner Match automatically next time."
            } catch { status = error.localizedDescription }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = Controller()
    private var item: NSStatusItem!
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let quitMenuItem = NSMenuItem(title: "Quit Corner Match", action: #selector(quit), keyEquivalent: "q"); quitMenuItem.target = self
        appMenu.addItem(quitMenuItem); appItem.submenu = appMenu; NSApp.mainMenu = mainMenu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Corner Match")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Corner Match…", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Corner Match", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items { entry.target = self }
        item.menu = menu
        showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 540), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Corner Match"; w.isReleasedWhenClosed = false
            w.collectionBehavior = [.transient, .ignoresCycle]
            w.contentViewController = NSHostingController(rootView: MainView(model: model))
            w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    // Native changes live inside InDesign and do not depend on this process.
    @objc func quit() { NSApp.terminate(nil) }
}

struct MainView: View {
    @ObservedObject var model: Controller
    private func chooseApplications() {
        let panel = NSOpenPanel(); panel.title = "Choose apps"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.addApplication(at: url) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Corner Match").font(.system(size: 24, weight: .semibold))
                Text("Native window corners").foregroundStyle(.secondary)
            }
            Text("Changes the window itself, including its shadow. InDesign keeps the effect when Corner Match is closed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Apply", action: model.apply).disabled(model.busy)
                Button("Restore originals", action: model.stop).disabled(model.busy)
                Spacer()
            }
            Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack { Text("Applications").font(.headline); Spacer(); Button("Add apps…", action: chooseApplications) }
            ScrollView {
                VStack(spacing: 0) {
                    if model.apps.isEmpty { Text("Add InDesign to get started.").foregroundStyle(.secondary).padding(12) }
                    ForEach(model.apps) { target in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: target.path ?? "/Applications")).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.name).lineLimit(1)
                                if !target.supportsNative { Text("Native adapter not available yet").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Toggle("Enable \(target.name)", isOn: Binding(get: { target.isEnabled && target.supportsNative }, set: { model.setApplication(target.id, enabled: $0) }))
                                .labelsHidden().disabled(!target.supportsNative || model.busy)
                            Button { model.removeApplication(target.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(target.name)")
                        }.padding(.horizontal, 12).padding(.vertical, 8)
                        Divider()
                    }
                }
            }.frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Toggle("Apply automatically when InDesign opens", isOn: Binding(get: { model.startWithInDesign }, set: model.setStartup))
            Text("You can quit this utility after applying. Restore originals also removes its InDesign startup script.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 490, height: 540)
    }
}
@main struct CornerMatch {
    static func main() {
        let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate
        app.run(); withExtendedLifetime(delegate) {}
    }
}
