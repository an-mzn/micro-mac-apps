import Darwin
import Foundation

public final class Cancellation: @unchecked Sendable {
    fileprivate let pipe = Pipe()
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        try? pipe.fileHandleForWriting.write(contentsOf: Data([1]))
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    fileprivate func check() throws {
        if isCancelled { throw UsageError.cancelled }
    }
}

public struct DeviceChallenge {
    public let url: URL
    public let code: String
}

public struct Client {
    public static let bundledCLI = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    public static func executable(override: String?) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let candidates = override.map { [$0] } ?? ([bundledCLI] + directories.map { $0 + "/codex" })
        let files = FileManager.default
        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            return candidate.hasPrefix("/")
                && files.fileExists(atPath: candidate, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && files.isExecutableFile(atPath: candidate)
        }.map { URL(fileURLWithPath: $0) }
    }

    public static func environment(home: URL, inherited: [String: String]) -> [String: String] {
        let keep: Set<String> = [
            "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "SYSTEMROOT"
        ]
        var env = inherited.filter { keep.contains($0.key.uppercased()) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["CODEX_HOME"] = home.path
        return env
    }

    public let binary: URL
    public let storage: Storage

    public init(binary: URL, storage: Storage) {
        self.binary = binary
        self.storage = storage
    }

    public func refresh(_ id: UUID, cancellation: Cancellation, timeout: TimeInterval = 25) throws -> (Identity, Snapshot) {
        try session(id, cancellation, timeout) { rpc in
            var identity = try rpc.readAccount(refreshToken: false)
            let limits: Limits
            do {
                limits = try rpc.decode(Limits.self, from: rpc.call("account/rateLimits/read"))
            } catch UsageError.signIn {
                identity = try rpc.readAccount(refreshToken: true)
                limits = try rpc.decode(Limits.self, from: rpc.call("account/rateLimits/read"))
            }
            if let expected = identity.workspaceID, let actual = limits.accountId, expected != actual {
                throw UsageError.rejected
            }
            return (identity, Snapshot(windows: limits.windows, creditBalance: limits.creditBalance,
                                       unlimitedCredits: limits.unlimitedCredits, bankedResetCount: limits.bankedResetCount))
        }
    }

    public func signIn(_ id: UUID, cancellation: Cancellation, timeout: TimeInterval = 600,
                       challenge: (DeviceChallenge) -> Void) throws -> Identity {
        try session(id, cancellation, timeout) { rpc in
            let result: [String: Any]
            do {
                result = try rpc.call("account/login/start", ["type": "chatgptDeviceCode"],
                                      deadline: DispatchTime.now() + 25)
            } catch UsageError.rejected { throw UsageError.device }
            guard result["type"] as? String == "chatgptDeviceCode",
                  let id = result["loginId"] as? String,
                  let code = result["userCode"] as? String,
                  let raw = result["verificationUrl"] as? String, let url = URL(string: raw),
                  url.scheme == "https", url.host == "auth.openai.com",
                  url.user == nil, url.password == nil, url.port == nil else { throw UsageError.malformed }
            challenge(DeviceChallenge(url: url, code: code))
            do {
                let completed = try rpc.waitForLogin(id)
                guard completed["success"] as? Bool == true else { throw UsageError.device }
            } catch UsageError.cancelled {
                try? rpc.send(["id": 999, "method": "account/login/cancel", "params": ["loginId": id]])
                throw UsageError.cancelled
            }
            return try rpc.readAccount(refreshToken: false)
        }
    }

    private func session<T>(_ id: UUID, _ cancellation: Cancellation, _ timeout: TimeInterval,
                            _ work: (RPC) throws -> T) throws -> T {
        try cancellation.check()
        let home = try storage.home(id)
        let rpc = try RPC(binary: binary, home: home, cancellation: cancellation, timeout: timeout)
        defer { rpc.close() }
        let result = try rpc.call("initialize", ["clientInfo": [
            "name": "codex_usage", "title": "Usage", "version": "0.1.0"
        ]], deadline: DispatchTime.now() + 10)
        guard let reported = result["codexHome"] as? String,
              URL(fileURLWithPath: reported).standardizedFileURL.path == home.path
        else { throw UsageError.isolation }
        try rpc.send(["method": "initialized"])
        return try work(rpc)
    }
}

private final class RPC {
    private let child = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    private let cancellation: Cancellation
    private let deadline: DispatchTime
    private var pending = Data()
    private var notifications: [[String: Any]] = []
    private var nextID = 0

    init(binary: URL, home: URL, cancellation: Cancellation, timeout: TimeInterval) throws {
        self.cancellation = cancellation
        deadline = DispatchTime.now() + timeout
        child.executableURL = binary
        child.arguments = ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\"",
                           "-c", "analytics.enabled=false", "-c", "model_provider=\"openai\""]
        child.currentDirectoryURL = home
        child.environment = Client.environment(home: home, inherited: ProcessInfo.processInfo.environment)
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [exited] _ in exited.signal() }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try child.run() } catch { throw UsageError.cli }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            if child.isRunning { child.terminate() }
            if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut, child.isRunning {
                kill(child.processIdentifier, SIGKILL)
            }
        }
        child.waitUntilExit()
        try? output.fileHandleForReading.close()
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw UsageError.exited }
    }

    func readAccount(refreshToken: Bool) throws -> Identity {
        try decode(AccountRead.self, from: call("account/read", ["refreshToken": refreshToken])).identity()
    }

    func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object)) }
        catch { throw UsageError.malformed }
    }

    func call(_ method: String, _ params: [String: Any]? = nil,
              deadline limit: DispatchTime? = nil) throws -> [String: Any] {
        try cancellation.check()
        nextID += 1
        let id = nextID
        var request: [String: Any] = ["id": id, "method": method]
        if let params { request["params"] = params }
        try send(request)
        while true {
            let message = try receive(until: min(deadline, limit ?? deadline))
            guard message["id"] as? Int == id, message["method"] == nil else {
                if message["method"] as? String == "account/login/completed", notifications.count < 8 {
                    notifications.append(message)
                }
                continue
            }
            if let error = message["error"] as? [String: Any] {
                let text = (error["message"] as? String ?? "").lowercased()
                if ["authentication required", "token expired", "unauthorized", "sign in", "sign-in required"].contains(where: text.contains) {
                    throw UsageError.signIn
                }
                if ["network", "connection", "error sending request", "dns", "offline"].contains(where: text.contains) {
                    throw UsageError.offline
                }
                throw UsageError.rejected
            }
            guard let result = message["result"] as? [String: Any] else { throw UsageError.malformed }
            return result
        }
    }

    func waitForLogin(_ id: String) throws -> [String: Any] {
        while true {
            try cancellation.check()
            let message = try notifications.isEmpty ? receive(until: deadline) : notifications.removeFirst()
            if message["method"] as? String == "account/login/completed",
               let params = message["params"] as? [String: Any], params["loginId"] as? String == id {
                return params
            }
        }
    }

    private func receive(until limit: DispatchTime) throws -> [String: Any] {
        let fd = output.fileHandleForReading.fileDescriptor
        let cancelFD = cancellation.pipe.fileHandleForReading.fileDescriptor
        while true {
            try cancellation.check()
            let now = DispatchTime.now().uptimeNanoseconds
            guard limit.uptimeNanoseconds > now else { throw UsageError.timeout }
            if let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                else { throw UsageError.malformed }
                return object
            }
            let ms = min(UInt64(Int32.max), (limit.uptimeNanoseconds - now) / 1_000_000 + 1)
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: cancelFD, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, 2, Int32(ms))
            if ready == 0 { throw UsageError.timeout }
            if ready < 0 && errno == EINTR { continue }
            try cancellation.check()
            guard ready > 0 else { throw UsageError.exited }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw UsageError.exited }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count <= 1_048_576 else { throw UsageError.malformed }
        }
    }
}
