import Foundation

public enum AntigravityStatus {
    private struct Payload: Decodable {
        let product: String
        let quota: [String: Bucket]
    }

    private struct Bucket: Decodable {
        let remaining_fraction: Double?
        let reset_time: String?
        let reset_in_seconds: Double?
        let disabled: Bool?
    }

    public static var identity: Identity {
        Identity(account: Account(type: "antigravity", email: nil, planType: nil,
                                  workspaceName: "Google Antigravity"), workspaceID: nil)
    }

    public static func read(path: String) throws -> Snapshot {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 65_536,
              let modified = values.contentModificationDate else { throw UsageError.malformed }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        guard payload.product == "antigravity" else { throw UsageError.malformed }
        let formatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions.insert(.withFractionalSeconds)
        let windows = payload.quota.keys.sorted().compactMap { key -> Window? in
            guard let bucket = payload.quota[key], bucket.disabled != true,
                  let fraction = bucket.remaining_fraction, (0...1).contains(fraction),
                  !key.isEmpty else { return nil }
            let reset = bucket.reset_time.flatMap { formatter.date(from: $0) ?? fractionalFormatter.date(from: $0) }
                ?? bucket.reset_in_seconds.flatMap {
                    $0.isFinite && $0 >= 0 ? modified.addingTimeInterval($0) : nil
                }
            let words = key.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
            let minutes = words.contains("weekly") ? 10_080 : (words.contains("daily") ? 1440 : nil)
            return Window(id: "antigravity:\(key)", bucket: key, slot: key, minutes: minutes,
                          used: 100 * (1 - fraction), reset: reset)
        }
        guard !windows.isEmpty else { throw UsageError.malformed }
        return Snapshot(at: modified, windows: windows)
    }
}
