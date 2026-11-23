import Foundation

/// Notices panes whose process was replaced (respawn-pane), which resets the pane without any output.
public struct RespawnTracker: Sendable {
    private struct Seen: Sendable {
        var pid: Int32
        var isDead: Bool
    }

    private var seen: [String: Seen] = [:]

    public init() {}

    /// Records `panes` and returns the sessions whose pane was respawned since the last update.
    /// A respawn is a live pane with a new process: its pid changed, or it was dead and now runs.
    /// Sessions that disappear are forgotten, so one created again under the same name is new.
    public mutating func update(_ panes: [PaneInfo]) -> Set<String> {
        var respawned: Set<String> = []
        var next: [String: Seen] = [:]
        for pane in panes {
            let previous = seen[pane.sessionName]
            if let previous, !pane.isDead, previous.isDead || previous.pid != pane.pid {
                respawned.insert(pane.sessionName)
            }
            next[pane.sessionName] = Seen(pid: pane.pid, isDead: pane.isDead)
        }
        seen = next
        return respawned
    }
}
