import Foundation

/// Removes the socket file a throwaway test server leaves in tmux's socket directory after `kill-server`.
func removeTmuxSocket(named socket: String) -> Void {
    let base = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp"
    try? FileManager.default.removeItem(atPath: "\(base)/tmux-\(getuid())/\(socket)")
}
