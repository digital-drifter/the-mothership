import Foundation

/// How often the app asks tmux for the session list. Each poll starts a `tmux list-panes` process
/// (about 5 ms of CPU), so a background app polls less often and lets the system batch its timer.
/// Terminal output is unaffected: it streams over control mode, not this poll.
public enum RefreshPolicy {
    public static func interval(appIsActive: Bool) -> Duration {
        appIsActive ? .seconds(1) : .seconds(5)
    }

    public static func tolerance(appIsActive: Bool) -> Duration {
        appIsActive ? .milliseconds(100) : .seconds(1)
    }
}
