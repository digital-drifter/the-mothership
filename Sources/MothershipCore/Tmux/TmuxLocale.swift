import Foundation

/// The environment every tmux process is started with.
///
/// An app opened from the Dock or Finder has no locale in its environment. tmux then treats its
/// client as non-UTF-8 and rewrites its output (tabs become underscores, non-ASCII is replaced), and
/// a server started that way hands the missing locale on to every program in every session.
public enum TmuxLocale {
    private static let variables = ["LC_ALL", "LC_CTYPE", "LANG"]

    /// `environment`, with `LANG` set to a UTF-8 locale unless the locale in effect is already UTF-8.
    public static func environment(from environment: [String: String]) -> [String: String] {
        // The first of these that is set and non-empty decides the character set, as in setlocale(3).
        let effective = variables.lazy.compactMap { environment[$0] }.first { !$0.isEmpty }
        if let effective, isUTF8(effective) { return environment }
        var result = environment
        result["LANG"] = "en_US.UTF-8"
        return result
    }

    private static func isUTF8(_ locale: String) -> Bool {
        let upper = locale.uppercased()
        return upper.contains("UTF-8") || upper.contains("UTF8")
    }
}
