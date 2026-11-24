import Foundation

/// A coding agent the app knows how to start.
public struct KnownAgent: Equatable, Sendable, Identifiable {
    /// Stable id stored in projects.json.
    public let id: String
    /// Shown in menus; also the prefix of the agent's tab names.
    public let name: String
    /// The command run in a login shell.
    public let run: String
}

/// The built-in agents, in the order they are listed.
public enum AgentCatalog {
    public static let all: [KnownAgent] = [
        KnownAgent(id: "claude", name: "Claude Code", run: "claude"),
        KnownAgent(id: "codex", name: "Codex", run: "codex"),
        KnownAgent(id: "gemini", name: "Gemini CLI", run: "gemini"),
        KnownAgent(id: "copilot", name: "GitHub Copilot", run: "copilot"),
        KnownAgent(id: "cursor", name: "Cursor Agent", run: "cursor-agent"),
        KnownAgent(id: "aider", name: "Aider", run: "aider"),
        KnownAgent(id: "opencode", name: "OpenCode", run: "opencode"),
        KnownAgent(id: "amp", name: "Amp", run: "amp"),
    ]

    /// Enabled when the file doesn't say.
    public static let defaultEnabled: [String] = ["claude"]
}
