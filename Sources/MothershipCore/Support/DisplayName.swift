import Foundation

public enum DisplayName {
    /// Replaces control characters (tab, newline, ...) with spaces. Display names are stored as tmux
    /// options and read back from tab-separated, line-based `list-panes` output.
    public static func clean(_ name: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            result.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        return String(result)
    }
}
