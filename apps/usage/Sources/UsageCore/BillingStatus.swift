import Foundation

public enum BillingStatus: String, Codable {
    case copilot, deepseek

    public var title: String {
        switch self {
        case .copilot: return "GitHub Copilot"
        case .deepseek: return "DeepSeek"
        }
    }

    public var identity: Identity {
        Identity(account: Account(type: rawValue, email: nil, planType: nil,
                                  workspaceName: title), workspaceID: nil)
    }

    private struct Payload: Decodable {
        let provider: BillingStatus
        let amounts: [UsageAmount]
    }

    public func read(path: String) throws -> Snapshot {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 65_536,
              let modified = values.contentModificationDate else { throw UsageError.malformed }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        guard payload.provider == self, (1...12).contains(payload.amounts.count),
              payload.amounts.allSatisfy({
                  !$0.label.isEmpty && $0.label.count <= 64 &&
                  $0.value.isFinite && $0.value >= 0
              }) else { throw UsageError.malformed }
        return Snapshot(at: modified, windows: [], amounts: payload.amounts)
    }
}

public struct UsageAmount: Codable, Equatable {
    public let label: String
    public let value: Double

    public var displayValue: String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
