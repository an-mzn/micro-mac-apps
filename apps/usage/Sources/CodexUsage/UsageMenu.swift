import AppKit
import ServiceManagement
import UsageCore
import WidgetKit

final class UsageMenu: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let appGroup = "group.com.an-mzn.codex-usage"
    private lazy var storage = makeStorage()
    private var config = Configuration()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private weak var settingsTabs: NSTabViewController?
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
    private var refreshBatch: Set<UUID> = []
    private var batchUpdated = false
    private var afterJob: [UUID: () -> Void] = [:]
    private var failures: [UUID: Failure] = [:]
    private var loginPanel: NSPanel?
    private var deviceCode: String?
    private weak var copyCodeButton: NSButton?
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

    private func makeStorage() -> Storage {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Usage", isDirectory: true)
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            do {
                try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let values = try FileManager.default.attributesOfItem(atPath: shared.path)
                if values[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()), access(shared.path, W_OK) == 0 {
                    return Storage(root: shared, homeRoot: support)
                }
            } catch { }
        }
        return Storage(root: support, homeRoot: support)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { config = try storage.load() }
        catch { storageProblem = true; loadFailed = true }
        let icon = Bundle.main.url(forResource: "codex-refresh", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
        icon?.size = NSSize(width: 20, height: 20)
        item.button?.image = icon
            ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Codex Usage")
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(showMenu)
        item.button?.sendAction(on: .leftMouseUp)
        popover.behavior = .transient
        popover.animates = false
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

    @objc private func showMenu() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        updatePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        beginRefreshBatch(manual: true)
    }

    private func updatePopover() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        if storageProblem { appendInfo("Could not read or save profile settings", to: stack) }
        if cli == nil { appendInfo("CLI unavailable · Select a binary in Settings", to: stack) }
        if config.profiles.isEmpty { appendInfo("No accounts connected", to: stack) }
        for (index, profile) in config.profiles.enumerated() {
            if index > 0 { appendDivider(to: stack) }
            let manage = NSMenu()
            action("Rename…", #selector(rename(_:)), in: manage, id: profile.id)
            action("Reauthenticate…", #selector(reauthenticate(_:)), in: manage, id: profile.id)
            action("Remove…", #selector(remove(_:)), in: manage, id: profile.id)
            let name = NSTextField(labelWithString: profile.label)
            name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            name.textColor = .labelColor
            let chevron = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Account actions")!,
                                   target: self, action: #selector(showAccountActions(_:)))
            chevron.isBordered = false
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.cell?.representedObject = manage
            let header = NSStackView(views: [name, NSView(), chevron])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 6
            header.widthAnchor.constraint(equalToConstant: 410).isActive = true
            stack.addArrangedSubview(header)
            if let snapshot = profile.snapshot {
                if snapshot.windows.isEmpty { appendInfo("No allowance windows returned", to: stack) }
                for window in snapshot.windows { appendUsageRow(window, to: stack) }
            }
            if let job = jobs[profile.id], job.work != .refresh {
                appendInfo(job.status, to: stack)
            } else if let failure = failures[profile.id] {
                appendInfo(failure.text, to: stack)
            }
            if profile.snapshot?.due(interval: interval) == true ||
                (profile.snapshot != nil && failures[profile.id] != nil) {
                appendInfo("Stale · Showing the last successful reading", to: stack)
            } else if profile.snapshot == nil && jobs[profile.id] == nil && failures[profile.id] == nil {
                appendInfo("Waiting for first reading", to: stack)
            }
        }
        appendDivider(to: stack)
        if !refreshBatch.isEmpty { appendInfo("Refreshing accounts…", to: stack) }
        if !config.profiles.isEmpty, let lastRefreshed = config.lastRefreshed {
            appendInfo("Last refreshed \(dateText(lastRefreshed))", to: stack, color: .secondaryLabelColor)
        }
        if let loginID {
            let show = NSButton(title: "Show Sign-In", target: self, action: #selector(showSignIn))
            show.isBordered = false
            show.alignment = .left
            stack.addArrangedSubview(show)
            let cancel = NSButton(title: "Cancel Sign-In", target: self, action: #selector(cancelSignIn))
            cancel.isBordered = false
            cancel.alignment = .left
            cancel.cell?.representedObject = loginID
            stack.addArrangedSubview(cancel)
        }
        let settings = NSButton(title: "Settings…", target: self, action: #selector(openSettingsFromPopover))
        settings.isBordered = false
        settings.alignment = .left
        stack.addArrangedSubview(settings)
        let quit = NSButton(title: "Quit Codex Usage", target: self, action: #selector(quitFromPopover))
        quit.isBordered = false
        quit.alignment = .left
        stack.addArrangedSubview(quit)
        stack.setFrameSize(stack.fittingSize)
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 438, height: stack.fittingSize.height)
    }

    private func appendUsageRow(_ window: Window, to stack: NSStackView) {
        let title = NSTextField(labelWithString: shortWindowTitle(window))
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.textColor = .labelColor
        let remaining = NSTextField(labelWithString: "\(window.remaining)% left")
        remaining.font = .systemFont(ofSize: NSFont.systemFontSize)
        remaining.textColor = .labelColor
        let reset = NSTextField(labelWithString: window.reset.map(dateText) ?? "")
        reset.font = .systemFont(ofSize: NSFont.systemFontSize)
        reset.textColor = .secondaryLabelColor
        reset.alignment = .right
        let row = NSStackView(views: [title, remaining, NSView(), reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(0, after: row.views[2])
        row.widthAnchor.constraint(equalToConstant: 410).isActive = true
        reset.widthAnchor.constraint(greaterThanOrEqualToConstant: 185).isActive = true
        stack.addArrangedSubview(row)
    }

    private func appendInfo(_ title: String, to stack: NSStackView, color: NSColor = .labelColor) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = color
        stack.addArrangedSubview(label)
    }

    private func appendDivider(to stack: NSStackView) {
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 410).isActive = true
        stack.addArrangedSubview(divider)
    }

    private func action(_ title: String, _ selector: Selector, in menu: NSMenu, id: UUID? = nil, key: String = "") {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        entry.representedObject = id
        menu.addItem(entry)
    }

    @objc private func showAccountActions(_ sender: NSButton) {
        guard let menu = sender.cell?.representedObject as? NSMenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY), in: sender)
    }

    @objc private func openSettingsFromPopover() {
        popover.performClose(nil)
        settings()
    }

    @objc private func quitFromPopover() {
        popover.performClose(nil)
        quit()
    }

    private func shortWindowTitle(_ window: Window) -> String {
        let duration: String
        switch window.minutes {
        case 300: duration = "5h"
        case 10_080: duration = "Wk"
        default: return window.title
        }
        return window.bucketID == "codex" ? duration : "\(window.bucket) · \(duration)"
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func updateIcon() {
        let mostAvailable = config.menuShowsMostAvailable == true ? config.mostAvailable : nil
        let profile = mostAvailable?.profile ?? config.profiles.first { $0.id == config.menuProfile }
        let windows = profile?.snapshot?.windows ?? []
        let showsBoth = config.menuWeeklyWindow != nil
        let window = mostAvailable?.window ?? windows.first { $0.id == config.menuWindow && (!showsBoth || $0.minutes == 300) }
        let week = windows.first { $0.id == config.menuWeeklyWindow && $0.minutes == 10_080 }
        var values = [window, week].compactMap { $0 }.map { "\($0.remaining)%" }
        if let mostAvailable { values.insert(mostAvailable.profile.label, at: 0) }
        let stale = profile.map { p in
            p.snapshot?.due(interval: interval) == true || failures[p.id] != nil || cli == nil
        } ?? false
        item.button?.title = values.isEmpty ? "" : " " + values.joined(separator: " · ") + (stale ? "*" : "")
        var details = [window, week].compactMap { $0 }.map { "\($0.title) · \($0.remaining)% left" }
        if let mostAvailable { details.insert(mostAvailable.profile.label, at: 0) }
        item.button?.toolTip = details.isEmpty ? "Codex Usage" :
            details.joined(separator: " | ") + (stale ? " · stale" : "")
        item.button?.setAccessibilityLabel(item.button?.toolTip ?? "Codex Usage")
    }

    private func commit(_ next: Configuration) throws {
        guard !loadFailed else { throw UsageError.rejected }
        try storage.save(next)
        config = next
        storageProblem = false
        if let settingsTabs, settingsTabs.tabView.tabViewItems.count > 1 {
            settingsTabs.tabView.tabViewItems[1].viewController = pageController(title: "Accounts", view: accountSettingsPage())
        }
        WidgetCenter.shared.reloadAllTimelines()
        updateIcon()
        if popover.isShown { updatePopover() }
    }

    private func change(_ edit: (inout Configuration) -> Void) {
        do {
            var next = config
            edit(&next)
            try commit(next)
        } catch {
            storageProblem = true
            alert("Could not save settings", "Check access to the shared Codex Usage storage.")
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard refreshBatch.isEmpty, !asleep, !quitPending, !ProcessInfo.processInfo.isLowPowerModeEnabled, cli != nil else { return }
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

    private func automatic() {
        defer { updateIcon(); schedule() }
        guard !asleep, !quitPending, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              Date() >= grace, cli != nil else { return }
        let now = Date()
        let hasDueAccount = config.profiles.contains { profile in
            guard jobs[profile.id] == nil else { return false }
            if let failure = failures[profile.id] { return failure.retry <= now }
            return profile.snapshot?.due(interval: interval, now: now) != false
        }
        if hasDueAccount { beginRefreshBatch() }
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
        if work == .refresh, refreshBatch.remove(id) != nil, refreshBatch.isEmpty, batchUpdated, !quitPending {
            change { $0.lastRefreshed = Date() }
        }
        if !quitPending { next?() }
        if quitPending && jobs.isEmpty { NSApp.reply(toApplicationShouldTerminate: true) }
        updateIcon()
        if popover.isShown { updatePopover() }
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
                self.batchUpdated = true
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
        beginRefreshBatch(manual: true)
    }

    private func beginRefreshBatch(manual: Bool = false) {
        guard refreshBatch.isEmpty, !quitPending, cli != nil else { return }
        let now = Date()
        let accounts = config.profiles.filter { profile in
            guard jobs[profile.id] == nil, afterJob[profile.id] == nil else { return false }
            return manual || failures[profile.id].map { $0.retry <= now } != false
        }
        refreshBatch = Set(accounts.map(\.id))
        batchUpdated = false
        if popover.isShown { updatePopover() }
        accounts.forEach { refresh($0.id) }
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
                        self.beginRefreshBatch()
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

    @objc private func copyDeviceCode() {
        guard let deviceCode else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(deviceCode, forType: .string) {
            copyCodeButton?.title = "Copied"
        }
    }

    private func endLogin() {
        deviceCode = nil
        copyCodeButton = nil
        loginPanel?.orderOut(nil)
        loginPanel = nil
        loginID = nil
    }

    private func showLoginPanel(_ message: String, challenge: DeviceChallenge? = nil) {
        let panel = loginPanel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "ChatGPT Sign-In"
        panel.hidesOnDeactivate = false
        deviceCode = challenge?.code
        copyCodeButton = nil
        let label = NSTextField(wrappingLabelWithString: message)
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        if let challenge {
            let code = NSButton(title: challenge.code, target: self, action: #selector(copyDeviceCode))
            code.isBordered = false
            code.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
            code.toolTip = "Click to copy the one-time code"
            code.setAccessibilityHelp("Copies the one-time code to the clipboard.")
            let copy = NSButton(title: "Copy", target: self, action: #selector(copyDeviceCode))
            copyCodeButton = copy
            let codeRow = NSStackView(views: [code, copy])
            codeRow.orientation = .horizontal
            codeRow.alignment = .centerY
            codeRow.spacing = 12
            stack.addArrangedSubview(codeRow)
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
        dialog.messageText = "Are you sure you want to remove \(profile.label)?"
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
                    if next.menuProfile == id {
                        next.menuProfile = nil
                        next.menuWindow = nil
                        next.menuWeeklyWindow = nil
                    }
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

    private struct DisplayOption {
        let profile: UUID
        let window: String
        let week: String?
    }

    @objc private func settings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let interval = NSPopUpButton()
        let choices = [5, 10, 15, 30, 60, 120]
        interval.addItems(withTitles: choices.map { "\($0) minutes" })
        interval.selectItem(at: choices.firstIndex(of: config.minutes) ?? 2)
        for (item, minutes) in zip(interval.itemArray, choices) { item.tag = minutes }
        interval.target = self
        interval.action = #selector(changeRefreshInterval(_:))
        interval.setAccessibilityLabel("Background refresh interval")
        let selection = NSPopUpButton()
        selection.setAccessibilityLabel("Menu bar allowance")
        selection.addItem(withTitle: "Icon only")
        selection.addItem(withTitle: "Most allowance available")
        selection.lastItem?.tag = 1
        selection.target = self
        selection.action = #selector(changeMenuDisplay(_:))
        let profileOptionsStart = selection.numberOfItems
        var options: [DisplayOption] = []
        func addOption(_ title: String, profile: UUID, window: String, week: String? = nil) {
            let option = DisplayOption(profile: profile, window: window, week: week)
            options.append(option)
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.representedObject = option
            selection.menu?.addItem(entry)
        }
        for profile in config.profiles {
            let windows = profile.snapshot?.windows ?? []
            for window in windows where window.minutes == 300 {
                if let week = windows.first(where: { $0.minutes == 10_080 && $0.bucketID == window.bucketID }) {
                    let prefix = window.bucketID == "codex" ? profile.label : "\(profile.label) · \(window.bucket)"
                    addOption("\(prefix) · 5h + Wk", profile: profile.id, window: window.id, week: week.id)
                }
            }
            for window in windows {
                addOption("\(profile.label) · \(shortWindowTitle(window))", profile: profile.id, window: window.id)
            }
        }
        if config.menuShowsMostAvailable == true {
            selection.selectItem(at: 1)
        } else if let profileID = config.menuProfile, let windowID = config.menuWindow,
           let profile = config.profiles.first(where: { $0.id == profileID }) {
            if let index = options.firstIndex(where: {
                $0.profile == profileID && $0.window == windowID && $0.week == config.menuWeeklyWindow
            }) {
                selection.selectItem(at: index + profileOptionsStart)
            } else {
                addOption("\(profile.label) · Saved display (reading unavailable)",
                          profile: profileID, window: windowID, week: config.menuWeeklyWindow)
                selection.selectItem(at: selection.numberOfItems - 1)
            }
        }
        let launch = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(changeLaunchAtLogin(_:)))
        launch.state = launchAtLoginEnabled ? .on : .off
        let binary = NSTextField(string: config.binary ?? "")
        binary.placeholderString = "Automatic discovery"
        binary.delegate = self
        binary.setAccessibilityLabel("Codex executable path")
        let choose = NSButton(title: "Choose Executable…", target: self, action: #selector(chooseBinary(_:)))
        choose.cell?.representedObject = binary
        let general = settingsPage([
            fieldRow("Background refresh", interval),
            fieldRow("Menu bar display", selection),
            launch,
            NSTextField(labelWithString: "Codex executable"),
            binary,
            choose
        ])
        let accountsPage = accountSettingsPage()
        let generalItem = NSTabViewItem(viewController: pageController(title: "General", view: general))
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let accountsItem = NSTabViewItem(viewController: pageController(title: "Accounts", view: accountsPage))
        accountsItem.label = "Accounts"
        accountsItem.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(generalItem)
        tabs.addTabViewItem(accountsItem)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Usage"
        window.contentViewController = tabs
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        settingsTabs = tabs
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func fieldRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    private func settingsPage(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24)
        ])
        return container
    }

    private func pageController(title: String, view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.title = title
        controller.view = view
        return controller
    }

    private func accountSettingsPage() -> NSView {
        let intro = NSTextField(labelWithString: "Manage connected ChatGPT accounts and refresh their usage.")
        intro.textColor = .secondaryLabelColor
        let refresh = NSButton(title: "Refresh All", target: self, action: #selector(refreshAll))
        refresh.keyEquivalent = "r"
        let addAccount = NSButton(title: "Add Account…", target: self, action: #selector(add))
        let details = NSButton(title: "Account Details…", target: self, action: #selector(accountDetails))
        details.isEnabled = !config.profiles.isEmpty
        let rows: [NSView] = config.profiles.map { profile in
            let name = NSTextField(labelWithString: profile.label)
            name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            let identity = NSTextField(labelWithString: profile.identity.context.isEmpty ? "Account details unavailable" : profile.identity.context)
            identity.textColor = .secondaryLabelColor
            identity.lineBreakMode = .byTruncatingTail
            let column = NSStackView(views: [name, identity])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 3
            return column
        }
        var content: [NSView] = [intro, refresh, addAccount, details]
        if !rows.isEmpty {
            let divider = NSBox()
            divider.boxType = .separator
            content.append(divider)
            content.append(contentsOf: rows)
        } else {
            let empty = NSTextField(labelWithString: "No accounts connected yet.")
            empty.textColor = .secondaryLabelColor
            content.append(empty)
        }
        return settingsPage(content)
    }

    @objc private func changeRefreshInterval(_ sender: NSPopUpButton) {
        guard let minutes = sender.selectedItem?.tag else { return }
        change { $0.minutes = minutes }
        sender.selectItem(withTag: config.minutes)
    }

    @objc private func changeMenuDisplay(_ sender: NSPopUpButton) {
        let option = sender.selectedItem?.representedObject as? DisplayOption
        change {
            $0.menuProfile = option?.profile
            $0.menuWindow = option?.window
            $0.menuWeeklyWindow = option?.week
            $0.menuShowsMostAvailable = sender.selectedItem?.tag == 1
        }
    }

    private var launchAtLoginEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    @objc private func changeLaunchAtLogin(_ sender: NSButton) {
        let wantsOn = sender.state == .on
        do {
            if wantsOn { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if wantsOn && SMAppService.mainApp.status == .requiresApproval {
                alert("Launch at login needs approval", "Enable Codex Usage in System Settings under General → Login Items.")
            }
        } catch {
            alert("Could not change launch at login", error.localizedDescription)
        }
        sender.state = launchAtLoginEnabled ? .on : .off
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        updateBinary(field)
    }

    private func updateBinary(_ field: NSTextField) {
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = path.isEmpty || Client.executable(override: path) != nil
        let warning = valid ? nil : "Choose an absolute path to an executable Codex binary."
        field.textColor = valid ? .labelColor : .systemRed
        field.toolTip = warning
        field.setAccessibilityHelp(warning)
        guard valid else { return }
        let binary = path.isEmpty ? nil : path
        if binary != config.binary { change { $0.binary = binary } }
    }

    @objc private func accountDetails() {
        let details = config.profiles.map { profile in
            let context = profile.identity.context
            return context.isEmpty ? profile.label : "\(profile.label)\n\(context)"
        }
        alert("Account Details", details.joined(separator: "\n\n"))
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
            settingsTabs = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func chooseBinary(_ sender: NSButton) {
        guard let field = sender.cell?.representedObject as? NSTextField else { return }
        let picker = NSOpenPanel()
        picker.message = "Select the Codex executable"
        picker.treatsFilePackagesAsDirectories = true
        if picker.runModal() == .OK, let url = picker.url {
            field.stringValue = url.path
            updateBinary(field)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
