import Foundation

/// Reads and writes the app-owned projects.json. The app is the only writer; nothing watches it.
///
/// A file that cannot be read (bad JSON, or a missing or unknown `version`) is renamed to
/// `projects.json.unreadable-<timestamp>` and the app starts empty, so the next save never
/// overwrites what the user had.
public struct ProjectStore: Sendable {
    public struct Loaded: Equatable, Sendable {
        public var config: MothershipConfig
        /// Set when the file was unreadable; says where it was kept.
        public var warning: String?
        /// False only when an unreadable file could not be moved aside, so saving would overwrite it.
        public var canSave: Bool

        public init(config: MothershipConfig, warning: String?, canSave: Bool) {
            self.config = config
            self.warning = warning
            self.canSave = canSave
        }
    }

    private struct UnsupportedVersion: Error, CustomStringConvertible {
        let version: Int
        var description: String { "unsupported version \(version)" }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mothership/projects.json")
    }

    /// The stored config; `.empty` when there is no file yet or it was unreadable.
    public func load(now: Date = Date()) -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Loaded(config: .empty, warning: nil, canSave: true)
        } catch {
            return keepAside(reason: error.localizedDescription, now: now)
        }
        do {
            let config = try JSONDecoder().decode(MothershipConfig.self, from: data)
            guard config.version == 1 else { throw UnsupportedVersion(version: config.version) }
            return Loaded(config: config, warning: nil, canSave: true)
        } catch {
            return keepAside(reason: Self.describe(error), now: now)
        }
    }

    /// Writes the config atomically, creating the folder if needed.
    public func save(_ config: MothershipConfig) throws -> Void {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private func keepAside(reason: String, now: Date) -> Loaded {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let keptName = "\(url.lastPathComponent).unreadable-\(formatter.string(from: now))"
        let kept = url.deletingLastPathComponent().appendingPathComponent(keptName)
        do {
            try FileManager.default.moveItem(at: url, to: kept)
        } catch {
            let warning = "Couldn't read projects.json (\(reason)), and it could not be moved aside "
                + "(\(error.localizedDescription)). Changes won't be saved until it is fixed or removed: \(url.path)"
            return Loaded(config: .empty, warning: warning, canSave: false)
        }
        let warning = "Couldn't read projects.json (\(reason)). It was kept as \(keptName); starting with no projects."
        return Loaded(config: .empty, warning: warning, canSave: true)
    }

    /// A short reason for the warning; DecodingError's default description is a wall of text.
    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted:
            return "not valid JSON"
        case DecodingError.keyNotFound(let key, let context):
            return "missing \"\(path(context.codingPath + [key]))\""
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "unexpected value at \"\(path(context.codingPath))\""
        default:
            return String(describing: error)
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
