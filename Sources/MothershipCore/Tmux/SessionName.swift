import Foundation

public enum ItemKind: String, Sendable, CaseIterable {
    case command = "cmd"
    case agent = "agent"
    case terminal = "term"
}

public enum SessionName {
    private static let idAlphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public static func make(projectSlug: String, kind: ItemKind, id: String) -> String {
        "ms-\(projectSlug)-\(kind.rawValue)-\(id)"
    }

    /// The `-t` target for exactly this session (and its only pane). A plain name is also matched as a
    /// prefix (`ms-p-cmd-vite` finds `ms-p-cmd-vite-dev`); `=` requires an exact match and the trailing `:`
    /// makes the target valid for commands that expect a pane. Verified on tmux 3.8 for attach-session,
    /// kill-session, respawn-pane, send-keys, set-option, display-message and capture-pane.
    public static func target(_ sessionName: String) -> String {
        "=\(sessionName):"
    }

    public static func randomID() -> String {
        String((0..<6).map { _ in idAlphabet.randomElement()! })
    }
}
