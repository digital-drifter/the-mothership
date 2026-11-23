import Foundation

public enum TmuxLocator {
    public static func find(
        environmentPath: String?,
        fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        for entry in (environmentPath ?? "").split(separator: ":") where !entry.isEmpty {
            candidates.append("\(entry)/tmux")
        }
        return candidates.first(where: fileExists)
    }
}
