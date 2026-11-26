import AppKit
import ServiceManagement
import UsageCore

final class UsageMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let storage = Storage(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Codex Usage", isDirectory: true))
    private var config = Configuration()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private enum Work: Equatable { case refresh, login, remove }
    private struct Job {
        let work: Work
        let token = Cancellation()
        let status: String
    }
    private struct Failure {
        let text: String
        let count: Int
        let retry: Date
    }
    private var jobs: [UUID: Job] = [:]
    private var afterJob: [UUID: () -> Void] = [:]
    private var failures: [UUID: Failure] = [:]
    private var loginPanel: NSPanel?
    private var loginID: UUID?
    private var timer: Timer?
    private var asleep = false
    private var quitPending = false
    private var grace = Date().addingTimeInterval(45)
    private var storageProblem = false
    private var loadFailed = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    private var interval: TimeInterval { Double(min(120, max(5, config.minutes))) * 60 }
    private var cli: URL? { Client.executable(override: config.binary) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { config = try storage.load() }
        catch { storageProblem = true; loadFailed = true }
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                                     accessibilityDescription: "Codex Usage")
            ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Codex Usage")
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.menu = menu
        menu.delegate = self
        updateIcon()
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            asleep = true
            schedule()
            jobs.values.filter { $0.work == .refresh }.forEach { $0.token.cancel() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            asleep = false
            grace = Date().addingTimeInterval(60)
            schedule()
        }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateIcon()
            self?.schedule()
        }
        schedule()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !jobs.isEmpty else { return .terminateNow }
        quitPending = true
        timer?.invalidate()
        afterJob.removeAll()
        jobs.values.forEach { $0.token.cancel() }
        return .terminateLater
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if storageProblem { info("Could not read or save profile settings", in: menu) }
        if cli == nil { info("CLI unavailable · Select a binary in Settings", in: menu) }
        if config.profiles.isEmpty {
            info("No accounts connected", in: menu)
        }
        for profile in config.profiles {
            menu.addItem(.separator())
            let label = profile.label
            let manage = NSMenu()
            let header = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            header.submenu = manage
            menu.addItem(header)
            let context = profile.identity.context
            if !context.isEmpty { info(context, in: menu) }
            if let snapshot = profile.snapshot {
                if snapshot.windows.isEmpty { info("No allowance windows returned", in: menu) }
                for window in snapshot.windows {
                    let reset = window.reset.map { " · resets \(dateText($0))" } ?? ""
                    let low = window.remaining <= 15 ? " · Low" : ""
                    info("\(window.title)   \(window.remaining)% left\(low)\(reset)", in: menu)
                }
                info("Updated \(dateText(snapshot.at))", in: menu)
            }
            if let job = jobs[profile.id] {
                info(job.status, in: menu)
            } else if let failure = failures[profile.id] {
                info(failure.text, in: menu)
            }
            if profile.snapshot?.due(interval: interval) == true ||
                (profile.snapshot != nil && failures[profile.id] != nil) {
                info("Stale · Showing the last successful reading", in: menu)
            } else if profile.snapshot == nil && jobs[profile.id] == nil && failures[profile.id] == nil {
                info("Waiting for first reading", in: menu)
            }
            action("Refresh Account", #selector(refreshOne(_:)), in: manage, id: profile.id)
            action("Rename…", #selector(rename(_:)), in: manage, id: profile.id)
            action("Reauthenticate…", #selector(reauthenticate(_:)), in: manage, id: profile.id)
            action("Remove…", #selector(remove(_:)), in: manage, id: profile.id)
        }
        menu.addItem(.separator())
        if let loginID {
            action("Show Sign-In", #selector(showSignIn), in: menu)
            action("Cancel Sign-In", #selector(cancelSignIn), in: menu, id: loginID)
        } else {
            action("Add Account…", #selector(add), in: menu)
        }
        action("Refresh All", #selector(refreshAll), in: menu, key: "r")
        action("Settings…", #selector(settings), in: menu, key: ",")
        action("Quit Codex Usage", #selector(quit), in: menu, key: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Leave visible cached rows in place during native menu tracking.
        DispatchQueue.main.async { [weak self] in self?.automatic(onOpen: true) }
    }

    private func info(_ title: String, in menu: NSMenu) {
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
    }

    private func action(_ title: String, _ selector: Selector, in menu: NSMenu, id: UUID? = nil, key: String = "") {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        entry.representedObject = id
        menu.addItem(entry)
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func updateIcon() {
        let profile = config.profiles.first { $0.id == config.menuProfile }
        let window = profile?.snapshot?.windows.first { $0.id == config.menuWindow }
        let stale = profile.map { p in
            p.snapshot?.due(interval: interval) == true || failures[p.id] != nil || cli == nil
        } ?? false
        item.button?.title = window.map { " \($0.remaining)%\(stale ? "*" : "")" } ?? ""
        item.button?.toolTip = window.map { "\($0.title) · \($0.remaining)% left\(stale ? " · stale" : "")" } ?? "Codex Usage"
        item.button?.setAccessibilityLabel(item.button?.toolTip ?? "Codex Usage")
    }

    private func commit(_ next: Configuration) throws {
        guard !loadFailed else { throw UsageError.rejected }
        try storage.save(next)
        config = next
        storageProblem = false
        updateIcon()
    }

    private func change(_ edit: (inout Configuration) -> Void) {
        do {
            var next = config
            edit(&next)
            try commit(next)
        } catch {
            storageProblem = true
            alert("Could not save settings", "Check access to the Codex Usage Application Support directory.")
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !asleep, !quitPending, !ProcessInfo.processInfo.isLowPowerModeEnabled, cli != nil else { return }
        let now = Date()
        let next = config.profiles.compactMap { profile -> Date? in
            guard jobs[profile.id] == nil else { return nil }
            if let failure = failures[profile.id] { return failure.retry == .distantFuture ? nil : failure.retry }
            guard let snapshot = profile.snapshot else { return now }
            let resets = snapshot.windows.compactMap(\.reset).filter { $0 > snapshot.at }
            return min(resets.min() ?? .distantFuture, snapshot.at.addingTimeInterval(interval))
        }.min()
        guard let next else { return }
        let timer = Timer(fire: max(grace, next, now.addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            self?.automatic()
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func automatic(onOpen: Bool = false) {
        defer { updateIcon(); schedule() }
        guard !asleep, !quitPending, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              (onOpen || Date() >= grace), cli != nil else { return }
        let now = Date()
        for profile in config.profiles {
            if let failure = failures[profile.id] {
                if failure.retry <= now { refresh(profile.id) }
            } else if profile.snapshot?.due(interval: interval, now: now) != false {
                refresh(profile.id)
            }
        }
    }

    private func start<T>(_ id: UUID, _ job: Job, perform: @escaping () throws -> T,
                          complete: @escaping (Result<T, Error>) -> Void) {
        precondition(jobs[id] == nil)
        jobs[id] = job
        queue.addOperation {
            let result = Result { try perform() }
            DispatchQueue.main.async {
                self.jobs.removeValue(forKey: id)
                self.finish(id, work: job.work, result, complete: complete)
            }
        }
        schedule()
    }

    private func finish<T>(_ id: UUID, work: Work, _ result: Result<T, Error>, complete: (Result<T, Error>) -> Void) {
        let next = afterJob.removeValue(forKey: id)
        if work != .refresh || (next == nil && !quitPending) { complete(result) }
        if !quitPending { next?() }
        if quitPending && jobs.isEmpty { NSApp.reply(toApplicationShouldTerminate: true) }
        updateIcon()
        schedule()
    }

    private func refresh(_ id: UUID) {
        guard !quitPending, jobs[id] == nil, afterJob[id] == nil,
              config.profiles.contains(where: { $0.id == id }) else { return }
        guard let cli else { return }
        let job = Job(work: .refresh, status: "Loading allowance…")
        let client = Client(binary: cli, storage: storage)
        start(id, job, perform: { try client.refresh(id, cancellation: job.token) }) { result in
            guard let index = self.config.profiles.firstIndex(where: { $0.id == id }) else { return }
            do {
                let (identity, snapshot) = try result.get()
                var next = self.config
                next.profiles[index].identity = identity
                next.profiles[index].snapshot = snapshot
                try self.commit(next)
                self.failures.removeValue(forKey: id)
            } catch let error as UsageError where error == .cancelled {
                return
            } catch {
                let count = min(5, (self.failures[id]?.count ?? 0) + 1)
                let delay = min(7200, self.interval * pow(2, Double(count - 1)))
                self.failures[id] = Failure(text: error.localizedDescription, count: count,
                                            retry: (error as? UsageError) == .signIn ? .distantFuture : Date().addingTimeInterval(delay))
            }
        }
    }

    @objc private func refreshAll() {
        guard cli != nil else { alert("CLI unavailable", "Select a Codex executable in Settings."); return }
        config.profiles.forEach { refresh($0.id) }
    }

    @objc private func refreshOne(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID {
            guard cli != nil else { alert("CLI unavailable", "Select a Codex executable in Settings."); return }
            refresh(id)
        }
    }

    @objc private func add() {
        guard loginID == nil else { return }
        if let label = prompt("Add Account", value: "", button: "Continue") {
            beginLogin(UUID(), label: label, existing: false)
        }
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = config.profiles.first(where: { $0.id == id }),
              let label = prompt("Rename Account", value: profile.label, button: "Rename") else { return }
        change { config in
            if let index = config.profiles.firstIndex(where: { $0.id == id }) {
                config.profiles[index].label = label
            }
        }
    }

    @objc private func reauthenticate(_ sender: NSMenuItem) {
        guard loginID == nil, let id = sender.representedObject as? UUID, jobs[id]?.work != .remove,
              let profile = config.profiles.first(where: { $0.id == id }) else { return }
        beginLogin(id, label: profile.label, existing: true)
    }

    private func beginLogin(_ id: UUID, label: String, existing: Bool) {
        guard loginID == nil, let cli else { alert("CLI unavailable", "Select a Codex executable in Settings."); return }
        guard !storageProblem else { alert("Profile settings unavailable", "Check access to Application Support."); return }
        loginID = id
        showLoginPanel("Starting device sign-in…")
        afterCurrentWork(id) {
            guard self.loginID == id else { return }
            let job = Job(work: .login, status: "Waiting for sign-in…")
            let client = Client(binary: cli, storage: self.storage)
            self.start(id, job, perform: {
                do {
                    return try client.signIn(id, cancellation: job.token) { challenge in
                        DispatchQueue.main.async {
                            guard self.loginID == id, !job.token.isCancelled else { return }
                            self.showLoginPanel("Choose the intended ChatGPT account and workspace in your browser. Enter this one-time code there.",
                                                challenge: challenge)
                        }
                    }
                } catch {
                    if !existing { try self.storage.remove(id) }
                    throw error
                }
            }) { result in
                self.endLogin()
                switch result {
                case .success(let identity):
                    do {
                        var next = self.config
                        if let index = next.profiles.firstIndex(where: { $0.id == id }) {
                            next.profiles[index].identity = identity
                            next.profiles[index].snapshot = nil
                        } else {
                            next.profiles.append(Profile(id: id, label: label, identity: identity))
                        }
                        try self.commit(next)
                        self.failures.removeValue(forKey: id)
                        self.refresh(id)
                    } catch {
                        self.storageProblem = true
                        if !existing {
                            self.queue.addOperation { try? self.storage.remove(id) }
                        }
                        if !self.quitPending { self.alert("Could not save account", error.localizedDescription) }
                    }
                case .failure(let error):
                    if !self.quitPending && (error as? UsageError) != .cancelled {
                        if existing {
                            self.failures[id] = Failure(text: error.localizedDescription, count: 0,
                                                        retry: Date().addingTimeInterval(self.interval))
                        }
                        self.alert("Sign-in failed", error.localizedDescription)
                    }
                }
            }
        }
    }

    private func afterCurrentWork(_ id: UUID, _ action: @escaping () -> Void) {
        if let job = jobs[id] {
            afterJob[id] = action
            job.token.cancel()
        } else {
            action()
        }
    }

    @objc private func showSignIn() {
        NSApp.activate(ignoringOtherApps: true)
        loginPanel?.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelSignIn() {
        guard let id = loginID else { return }
        if jobs[id]?.work == .login {
            jobs[id]?.token.cancel()
            showLoginPanel("Cancelling sign-in…")
        } else {
            afterJob.removeValue(forKey: id)
            endLogin()
        }
    }

    @objc private func openVerification(_ sender: NSButton) {
        if let url = sender.identifier.map(\.rawValue).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }

    private func endLogin() {
        loginPanel?.orderOut(nil)
        loginPanel = nil
        loginID = nil
    }

    private func showLoginPanel(_ message: String, challenge: DeviceChallenge? = nil) {
        let panel = loginPanel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "ChatGPT Sign-In"
        panel.hidesOnDeactivate = false
        let label = NSTextField(wrappingLabelWithString: message)
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        if let challenge {
            let code = NSTextField(labelWithString: challenge.code)
            code.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
            code.isSelectable = true
            stack.addArrangedSubview(code)
            let browser = NSButton(title: "Open Verification Page", target: self, action: #selector(openVerification(_:)))
            browser.keyEquivalent = "\r"
            browser.identifier = NSUserInterfaceItemIdentifier(challenge.url.absoluteString)
            stack.addArrangedSubview(browser)
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSignIn))
        cancel.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(cancel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20)
        ])
        panel.contentView = view
        if loginPanel == nil { panel.center() }
        loginPanel = panel
        showSignIn()
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, id != loginID, jobs[id]?.work != .remove,
              let profile = config.profiles.first(where: { $0.id == id }) else { return }
        let dialog = NSAlert()
        dialog.messageText = "Remove \(profile.label)?"
        dialog.informativeText = "This deletes the tracker’s cached allowance and its private Codex sign-in."
        dialog.addButton(withTitle: "Cancel")
        dialog.addButton(withTitle: "Remove").hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertSecondButtonReturn else { return }
        afterCurrentWork(id) {
            let job = Job(work: .remove, status: "Removing…")
            self.start(id, job, perform: { try self.storage.remove(id) }) { result in
                do {
                    try result.get()
                    var next = self.config
                    next.profiles.removeAll { $0.id == id }
                    if next.menuProfile == id { next.menuProfile = nil; next.menuWindow = nil }
                    try self.commit(next)
                    self.failures.removeValue(forKey: id)
                } catch {
                    if !self.quitPending { self.alert("Could not remove account", error.localizedDescription) }
                }
            }
        }
    }

    private func prompt(_ title: String, value: String, button: String) -> String? {
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = "Enter a label that identifies this account or workspace."
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        dialog.accessoryView = field
        dialog.addButton(withTitle: button)
        dialog.addButton(withTitle: "Cancel")
        dialog.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return nil }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : String(label.prefix(80))
    }

    private func alert(_ title: String, _ message: String) {
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        dialog.runModal()
    }

    @objc private func settings() {
        let dialog = NSAlert()
        dialog.messageText = "Codex Usage Settings"
        let interval = NSPopUpButton()
        let choices = [5, 10, 15, 30, 60, 120]
        interval.addItems(withTitles: choices.map { "\($0) minutes" })
        interval.selectItem(at: choices.firstIndex(of: config.minutes) ?? 2)
        interval.setAccessibilityLabel("Background refresh interval")
        let selection = NSPopUpButton()
        selection.setAccessibilityLabel("Menu bar allowance")
        selection.addItem(withTitle: "Icon only")
        var pairs: [(UUID, String)] = []
        for profile in config.profiles {
            for window in profile.snapshot?.windows ?? [] {
                pairs.append((profile.id, window.id))
                selection.menu?.addItem(NSMenuItem(title: "\(profile.label) · \(window.title)",
                                                   action: nil, keyEquivalent: ""))
            }
        }
        if let index = pairs.firstIndex(where: { $0.0 == config.menuProfile && $0.1 == config.menuWindow }) {
            selection.selectItem(at: index + 1)
        }
        let loginBefore = SMAppService.mainApp.status
        let launch = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
        launch.state = (loginBefore == .enabled || loginBefore == .requiresApproval) ? .on : .off
        let binary = NSTextField(string: config.binary ?? "")
        binary.placeholderString = "Automatic discovery"
        binary.setAccessibilityLabel("Codex executable path")
        let choose = NSButton(title: "Choose Executable…", target: self, action: #selector(chooseBinary(_:)))
        choose.cell?.representedObject = binary
        let stack = NSStackView(views: [NSTextField(labelWithString: "Background refresh"), interval,
                                       NSTextField(labelWithString: "Menu bar display"), selection, launch,
                                       NSTextField(labelWithString: "Codex executable"), binary, choose])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        binary.widthAnchor.constraint(equalToConstant: 380).isActive = true
        stack.setFrameSize(stack.fittingSize)
        dialog.accessoryView = stack
        dialog.addButton(withTitle: "Save")
        dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let path = binary.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || Client.executable(override: path) != nil else {
            alert("CLI unavailable", "Choose an absolute path to an executable Codex binary.")
            return
        }
        let index = selection.indexOfSelectedItem - 1
        let pair = pairs.indices.contains(index) ? pairs[index] : nil
        change {
            $0.minutes = choices[max(0, interval.indexOfSelectedItem)]
            $0.binary = path.isEmpty ? nil : path
            $0.menuProfile = pair?.0
            $0.menuWindow = pair?.1
        }
        do {
            let wasOn = loginBefore == .enabled || loginBefore == .requiresApproval
            let wantsOn = launch.state == .on
            if wantsOn != wasOn {
                if wantsOn { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            }
            if wantsOn && SMAppService.mainApp.status == .requiresApproval {
                alert("Launch at login needs approval", "Enable Codex Usage in System Settings under General → Login Items.")
            }
        } catch {
            alert("Could not change launch at login", error.localizedDescription)
        }
    }

    @objc private func chooseBinary(_ sender: NSButton) {
        guard let field = sender.cell?.representedObject as? NSTextField else { return }
        let picker = NSOpenPanel()
        picker.message = "Select the Codex executable"
        picker.treatsFilePackagesAsDirectories = true
        if picker.runModal() == .OK, let url = picker.url { field.stringValue = url.path }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
