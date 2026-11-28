import Foundation

public struct ClaudeStatus: Decodable {
    private struct Reading: Decodable {
        let used_percentage: Double?
        let resets_at: Double?
    }

    private struct Limits: Decodable {
        let five_hour: Reading?
        let seven_day: Reading?
    }

    private let rate_limits: Limits?

    public static var identity: Identity {
        Identity(account: Account(type: "claude", email: nil, planType: nil, workspaceName: "Claude Code"), workspaceID: nil)
    }

    public static func read(path: String) throws -> Snapshot {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 65_536,
              let modified = values.contentModificationDate else { throw UsageError.malformed }
        let status = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let readings = [(300, "Primary", status.rate_limits?.five_hour),
                        (10_080, "Secondary", status.rate_limits?.seven_day)]
        let windows = readings.compactMap { minutes, slot, reading -> Window? in
            guard let used = reading?.used_percentage, (0...100).contains(used) else { return nil }
            let reset = reading?.resets_at.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            return Window(id: "claude:\(slot)", bucket: "Claude", slot: slot, minutes: minutes, used: used, reset: reset)
        }
        guard !windows.isEmpty else { throw UsageError.malformed }
        return Snapshot(at: modified, windows: windows)
    }
}
