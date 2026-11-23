import Foundation

public enum TmuxConfig {
    public static let contents: String = """
    set -g history-limit 50000
    set -g escape-time 0
    set -g default-terminal "xterm-256color"
    set -g remain-on-exit on
    set -g mouse off
    set -g status off
    set -g window-size latest
    set -g prefix None
    unbind C-b

    """

    /// Writes `tmux.conf` into `directory` (creating it if needed) and returns the file URL.
    public static func install(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tmux.conf")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
