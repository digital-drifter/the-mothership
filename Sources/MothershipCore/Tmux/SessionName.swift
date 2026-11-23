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

    public static func randomID() -> String {
        String((0..<6).map { _ in idAlphabet.randomElement()! })
    }
}
