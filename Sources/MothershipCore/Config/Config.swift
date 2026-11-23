import Foundation

public struct MothershipConfig: Equatable, Sendable {
    public var projects: [ProjectConfig]

    public init(projects: [ProjectConfig]) {
        self.projects = projects
    }
}

public struct ProjectConfig: Equatable, Sendable {
    public var name: String
    public var slug: String
    public var path: String
    public var commands: [CommandConfig]
    public var agents: [AgentTemplate]

    public init(name: String, slug: String, path: String, commands: [CommandConfig], agents: [AgentTemplate]) {
        self.name = name
        self.slug = slug
        self.path = path
        self.commands = commands
        self.agents = agents
    }
}

public struct CommandConfig: Equatable, Sendable {
    public var name: String
    public var slug: String
    public var run: String
    public var autostart: Bool

    public init(name: String, slug: String, run: String, autostart: Bool) {
        self.name = name
        self.slug = slug
        self.run = run
        self.autostart = autostart
    }
}

public struct AgentTemplate: Equatable, Sendable {
    public var name: String
    public var run: String

    public init(name: String, run: String) {
        self.name = name
        self.run = run
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case invalidYAML(String)
    case missingField(String)
    case duplicateName(String)

    public var description: String {
        switch self {
        case .invalidYAML(let detail):
            return "The config file is not valid YAML: \(detail)"
        case .missingField(let path):
            return "The config is missing a required value: \(path)"
        case .duplicateName(let detail):
            return "The config has a duplicate name. \(detail)"
        }
    }
}
