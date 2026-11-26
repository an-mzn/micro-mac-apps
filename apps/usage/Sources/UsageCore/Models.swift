import Foundation

public struct Account: Codable, Equatable {
    public let type: String
    public let email: String?
    public let planType: String?
    public let workspaceName: String?
}

public struct AccountRead: Decodable {
    public struct Routing: Decodable {
        public let chatgptAccountId: String?
    }
    public let account: Account?
    public let workspaceRouting: Routing?

    public func identity() throws -> Identity {
        guard let account, account.type == "chatgpt" else { throw UsageError.signIn }
        return Identity(account: account, workspaceID: workspaceRouting?.chatgptAccountId)
    }
}

public struct Identity: Codable, Equatable {
    public let account: Account
    public let workspaceID: String?

    public var context: String {
        [account.email, account.workspaceName ?? workspaceID.map { "Workspace \($0.prefix(8))" },
         account.planType].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct Window: Codable, Equatable {
    public let id: String
    public let bucket: String
    public let slot: String
    public let minutes: Int?
    public let used: Double
    public let reset: Date?

    public var bucketID: String {
        String(id.dropLast(slot.count + 1))
    }

    public var remaining: Int { Int(max(0, min(100, 100 - used)).rounded()) }

    public var title: String {
        let duration: String
        switch minutes {
        case 10_080: duration = "Weekly"
        case let value? where [40_320, 43_200, 44_640].contains(value):
            duration = "Monthly (\(value / 1440) days)"
        case let value? where value > 0 && value % 1440 == 0: duration = "\(value / 1440) days"
        case let value? where value > 0 && value % 60 == 0: duration = "\(value / 60) hours"
        case let value? where value > 0: duration = "\(value) min"
        default: duration = slot
        }
        return "\(bucket) · \(duration)"
    }
}

public struct Limits: Decodable {
    struct Bucket: Decodable {
        struct Reading: Decodable {
            let usedPercent: Double
            let windowDurationMins: Int?
            let resetsAt: Double?
        }
        let limitId: String?
        let limitName: String?
        let primary: Reading?
        let secondary: Reading?
    }
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?
    public let accountId: String?

    public var windows: [Window] {
        var buckets = rateLimitsByLimitId ?? [:]
        if let legacy = rateLimits {
            let id = legacy.limitId ?? "codex"
            if buckets[id] == nil { buckets[id] = legacy }
        }
        return buckets.keys.sorted().flatMap { key -> [Window] in
            guard let bucket = buckets[key] else { return [] }
            return [("Primary", bucket.primary), ("Secondary", bucket.secondary)].compactMap { slot, reading in
                guard let reading, reading.usedPercent.isFinite else { return nil }
                return Window(id: "\(key):\(slot)", bucket: bucket.limitName ?? bucket.limitId ?? key,
                              slot: slot, minutes: reading.windowDurationMins, used: reading.usedPercent,
                              reset: reading.resetsAt.map(Date.init(timeIntervalSince1970:)))
            }
        }
    }
}

public struct Snapshot: Codable, Equatable {
    public let at: Date
    public let windows: [Window]

    public init(at: Date = Date(), windows: [Window]) {
        self.at = at
        self.windows = windows
    }

    public func due(interval: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(at) >= interval || windows.contains {
            guard let reset = $0.reset else { return false }
            return reset > at && reset <= now
        }
    }
}

public struct Profile: Codable, Equatable, Identifiable {
    public let id: UUID
    public var label: String
    public var identity: Identity
    public var snapshot: Snapshot?

    public init(id: UUID, label: String, identity: Identity, snapshot: Snapshot? = nil) {
        self.id = id
        self.label = label
        self.identity = identity
        self.snapshot = snapshot
    }
}

public struct Configuration: Codable, Equatable {
    public var profiles: [Profile] = []
    public var minutes = 15
    public var binary: String?
    public var menuProfile: UUID?
    public var menuWindow: String?
    public var menuWeeklyWindow: String?
    public init() {}
}

public enum UsageError: LocalizedError, Equatable {
    case cli, isolation, signIn, offline, timeout, cancelled, malformed, exited, rejected, device

    public var errorDescription: String? {
        switch self {
        case .cli: return "CLI unavailable"
        case .isolation: return "Could not validate the private profile directory"
        case .signIn: return "Sign-in required"
        case .offline: return "Offline or usage service unreachable"
        case .timeout: return "Request timed out"
        case .cancelled: return "Cancelled"
        case .malformed: return "Unexpected Codex response"
        case .exited: return "Codex exited unexpectedly"
        case .rejected: return "Codex could not complete the request"
        case .device: return "Device sign-in failed. Check that device code authorization is enabled in ChatGPT settings and allowed by your workspace."
        }
    }
}
