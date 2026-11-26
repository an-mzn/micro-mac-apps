import Foundation

public struct Storage {
    public let root: URL
    private let homeRoot: URL

    public init(root: URL, homeRoot: URL? = nil) {
        self.root = root.standardizedFileURL
        self.homeRoot = (homeRoot ?? root).standardizedFileURL
    }

    private var file: URL { root.appendingPathComponent("settings.json") }
    private let legacyRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Usage", isDirectory: true)
    private var legacyFile: URL { legacyRoot.appendingPathComponent("settings.json") }

    public func load() throws -> Configuration {
        try prepare(root)
        do {
            return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if root != legacyRoot, FileManager.default.fileExists(atPath: legacyFile.path),
               let legacy = try? JSONDecoder().decode(Configuration.self, from: Data(contentsOf: legacyFile)) {
                try save(legacy)
                return legacy
            }
            return Configuration()
        }
    }

    public func save(_ value: Configuration) throws {
        try prepare(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
    }

    public func home(_ id: UUID) throws -> URL {
        let parent = homeRoot.appendingPathComponent("Profiles", isDirectory: true)
        let home = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        try prepare(homeRoot)
        try prepare(parent, allowedUnder: homeRoot)
        try prepare(home, allowedUnder: parent)
        return home
    }

    public func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: home(id)) }

    private func prepare(_ url: URL, allowedUnder: URL? = nil) throws {
        let path = url.path
        let safeAncestor = allowedUnder?.standardizedFileURL.path
        guard url.resolvingSymlinksInPath().path == path,
              path != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path,
              safeAncestor == nil || path == safeAncestor || path.hasPrefix(safeAncestor! + "/") else {
            throw UsageError.isolation
        }
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try manager.attributesOfItem(atPath: path)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              values[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()),
              url.resolvingSymlinksInPath().path == path else { throw UsageError.isolation }
        if (values[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
    }
}
