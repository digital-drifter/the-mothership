import Foundation

public enum RelativePath {
    /// The value to store for a folder picked as a command's working directory: blank for the project folder
    /// itself, a path relative to the project when inside it, and the absolute path otherwise.
    public static func storedDirectory(picked: String, projectPath: String) -> String {
        let picked = URL(fileURLWithPath: picked).standardizedFileURL.path
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        if picked == project { return "" }
        let prefix = project + "/"
        return picked.hasPrefix(prefix) ? String(picked.dropFirst(prefix.count)) : picked
    }
}
