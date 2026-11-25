import Foundation

/// Everything the app stores in projects.json.
public struct MothershipConfig: Codable, Equatable, Sendable {
    public var version: Int
    /// Ids of the catalogue agents offered in every project's New Agent menu.
    public var enabledAgents: [String]
    public var projects: [ProjectConfig]

    /// What the app starts with when there is no file: the default enabled agents and no projects.
    public static var empty: MothershipConfig {
        MothershipConfig(version: 1, enabledAgents: AgentCatalog.defaultEnabled, projects: [])
    }

    public init(version: Int, enabledAgents: [String], projects: [ProjectConfig]) {
        self.version = version
        self.enabledAgents = enabledAgents
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabledAgents, projects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        enabledAgents = try container.decodeIfPresent([String].self, forKey: .enabledAgents) ?? AgentCatalog.defaultEnabled
        projects = try container.decode([ProjectConfig].self, forKey: .projects)
    }
}

public struct ProjectConfig: Codable, Equatable, Sendable {
    /// Stored and never changed, so tmux session names stay valid across renames.
    public var slug: String
    public var name: String
    /// Absolute folder path.
    public var path: String
    public var commands: [CommandConfig]
    /// Session names of agents in the order the user arranged them. Sessions not listed come after, oldest first.
    public var agentOrder: [String]
    /// Session names of terminals in the order the user arranged them. Sessions not listed come after, oldest first.
    public var terminalOrder: [String]

    public init(
        slug: String, name: String, path: String, commands: [CommandConfig],
        agentOrder: [String] = [], terminalOrder: [String] = []
    ) {
        self.slug = slug
        self.name = name
        self.path = path
        self.commands = commands
        self.agentOrder = agentOrder
        self.terminalOrder = terminalOrder
    }

    private enum CodingKeys: String, CodingKey {
        case slug, name, path, commands, agentOrder, terminalOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        commands = try container.decode([CommandConfig].self, forKey: .commands)
        agentOrder = try container.decodeIfPresent([String].self, forKey: .agentOrder) ?? []
        terminalOrder = try container.decodeIfPresent([String].self, forKey: .terminalOrder) ?? []
    }

    /// Where `command` runs: the project folder, or the command's own directory (relative to the project
    /// folder, or absolute). Blank means the project folder.
    public func workingDirectory(for command: CommandConfig) -> String {
        Self.resolve(directory: command.directory, projectPath: path)
    }

    /// Resolves a stored directory: blank is the project folder, `~` is the home folder, a relative path is
    /// relative to the project folder.
    public static func resolve(directory: String?, projectPath: String) -> String {
        var directory = (directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if directory.isEmpty { return projectPath }
        directory = (directory as NSString).expandingTildeInPath
        let full = directory.hasPrefix("/") ? directory : projectPath + "/" + directory
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
