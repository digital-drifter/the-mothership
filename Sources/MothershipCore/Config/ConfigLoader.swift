import Foundation
import Yams

public enum ConfigLoader {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/mothership/projects.yml")
    }

    public static let exampleYAML: String = """
    # The Mothership: projects, commands and agent templates.
    # Uncomment and edit the example below, then save; the app reloads automatically.
    #
    # projects:
    #   - name: Acme
    #     path: ~/Code/acme
    #     commands:
    #       - name: Vite
    #         run: npm run dev
    #         autostart: true
    #       - name: Queue
    #         run: php artisan queue:work
    #     agents:
    #       - name: Claude
    #         run: claude
    #       - name: Codex
    #         run: codex

    """

    private struct RawConfig: Decodable {
        var projects: [RawProject]?
    }

    private struct RawProject: Decodable {
        var name: String?
        var path: String?
        var commands: [RawCommand]?
        var agents: [RawAgent]?
    }

    private struct RawCommand: Decodable {
        var name: String?
        var run: String?
        var autostart: Bool?
    }

    private struct RawAgent: Decodable {
        var name: String?
        var run: String?
    }

    public static func parse(_ yaml: String, homeDirectory: String) throws -> MothershipConfig {
        let raw: RawConfig
        do {
            // An empty or comment-only document composes to nil: zero projects, not an error.
            guard try Yams.compose(yaml: yaml) != nil else { return MothershipConfig(projects: []) }
            raw = try YAMLDecoder().decode(RawConfig.self, from: yaml)
        } catch {
            throw ConfigError.invalidYAML(String(describing: error))
        }

        var projects: [ProjectConfig] = []
        for (pIndex, rawProject) in (raw.projects ?? []).enumerated() {
            let prefix = "projects[\(pIndex)]"
            let name = DisplayName.clean(try required(rawProject.name, "\(prefix).name"))
            let path = try required(rawProject.path, "\(prefix).path")

            var commands: [CommandConfig] = []
            for (cIndex, rawCommand) in (rawProject.commands ?? []).enumerated() {
                let cPrefix = "\(prefix).commands[\(cIndex)]"
                let cName = DisplayName.clean(try required(rawCommand.name, "\(cPrefix).name"))
                let run = try required(rawCommand.run, "\(cPrefix).run")
                commands.append(CommandConfig(
                    name: cName, slug: Slug.make(cName), run: run, autostart: rawCommand.autostart ?? false
                ))
            }

            var agents: [AgentTemplate] = []
            for (aIndex, rawAgent) in (rawProject.agents ?? []).enumerated() {
                let aPrefix = "\(prefix).agents[\(aIndex)]"
                let aName = DisplayName.clean(try required(rawAgent.name, "\(aPrefix).name"))
                let run = try required(rawAgent.run, "\(aPrefix).run")
                agents.append(AgentTemplate(name: aName, run: run))
            }

            try ensureUnique(commands.map { ($0.slug, $0.name) }) {
                "Two commands in \"\(name)\" share the slug \"\($0)\": \($1)"
            }
            try ensureUnique(agents.map { ($0.name, $0.name) }) { key, _ in
                "Two agent templates in \"\(name)\" share the name \"\(key)\""
            }

            projects.append(ProjectConfig(
                name: name,
                slug: Slug.make(name),
                path: expandTilde(path, home: homeDirectory),
                commands: commands,
                agents: agents
            ))
        }

        try ensureUnique(projects.map { ($0.slug, $0.name) }) {
            "Two projects share the slug \"\($0)\": \($1)"
        }
        return MothershipConfig(projects: projects)
    }

    public static func load(from url: URL) throws -> MothershipConfig {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.invalidYAML("Could not read \(url.path): \(error.localizedDescription)")
        }
        return try parse(text, homeDirectory: NSHomeDirectory())
    }

    public static func ensureExists(at url: URL) throws -> Void {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try exampleYAML.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func required(_ value: String?, _ path: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigError.missingField(path)
        }
        return value
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// Throws when two entries share a key; `message` receives the key and the offending display names.
    private static func ensureUnique(_ entries: [(key: String, name: String)], message: (String, String) -> String) throws -> Void {
        var seen: [String: String] = [:]
        for entry in entries {
            if let first = seen[entry.key] {
                throw ConfigError.duplicateName(message(entry.key, "\"\(first)\", \"\(entry.name)\""))
            }
            seen[entry.key] = entry.name
        }
    }
}
