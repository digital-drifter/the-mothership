import Foundation

/// Everything the app stores in projects.json.
public struct MothershipConfig: Codable, Equatable, Sendable {
    public var version: Int
    /// Agent templates shared by every project.
    public var agents: [AgentTemplate]
    public var projects: [ProjectConfig]

    public static let defaultAgents: [AgentTemplate] = [
        AgentTemplate(name: "Claude", run: "claude"),
        AgentTemplate(name: "Codex", run: "codex"),
    ]

    /// What the app starts with when there is no file: the default agents and no projects.
    public static var empty: MothershipConfig {
        MothershipConfig(version: 1, agents: defaultAgents, projects: [])
    }

    public init(version: Int, agents: [AgentTemplate], projects: [ProjectConfig]) {
        self.version = version
        self.agents = agents
        self.projects = projects
    }
}

public struct ProjectConfig: Codable, Equatable, Sendable {
    /// Stored and never changed, so tmux session names stay valid across renames.
    public var slug: String
    public var name: String
    /// Absolute folder path.
    public var path: String
    public var commands: [CommandConfig]

    public init(slug: String, name: String, path: String, commands: [CommandConfig]) {
        self.slug = slug
        self.name = name
        self.path = path
        self.commands = commands
    }

    /// Where `command` runs: the project folder, or the command's own directory (relative to the project
    /// folder, or absolute). Blank means the project folder.
    public func workingDirectory(for command: CommandConfig) -> String {
        let directory = (command.directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if directory.isEmpty { return path }
        let full = directory.hasPrefix("/") ? directory : path + "/" + directory
        return URL(fileURLWithPath: full).standardizedFileURL.path
    }
}

public struct CommandConfig: Codable, Equatable, Sendable {
    /// Stored and never changed, so the command's tmux session name stays valid across renames.
    public var slug: String
    public var name: String
    public var run: String
    public var autostart: Bool
    /// Where the command runs: relative to the project folder, or absolute. Nil means the project folder.
    public var directory: String?

    public init(slug: String, name: String, run: String, autostart: Bool, directory: String? = nil) {
        self.slug = slug
        self.name = name
        self.run = run
        self.autostart = autostart
        self.directory = directory
    }
}

public struct AgentTemplate: Codable, Equatable, Sendable {
    public var name: String
    public var run: String

    public init(name: String, run: String) {
        self.name = name
        self.run = run
    }
}
