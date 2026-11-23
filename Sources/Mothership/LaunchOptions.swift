import Foundation
import MothershipCore

/// Launch-time settings. Each can be overridden through UserDefaults, which includes launch
/// arguments, e.g. `open build/Mothership.app --args -configPath /tmp/x.yml -tmuxSocket ms-dev`.
struct LaunchOptions {
    /// The projects.yml file (`configPath` override).
    var configURL: URL
    /// The private tmux server's socket name (`tmuxSocket` override).
    var socketName: String
    /// Pretend tmux is not installed (`forceTmuxMissing`), to test the missing-tmux screen.
    var forceTmuxMissing: Bool

    static func current(_ defaults: UserDefaults = .standard) -> LaunchOptions {
        let configURL = nonEmpty(defaults.string(forKey: "configPath"))
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        return LaunchOptions(
            configURL: configURL ?? ConfigLoader.defaultURL,
            socketName: nonEmpty(defaults.string(forKey: "tmuxSocket")) ?? "mothership",
            forceTmuxMissing: defaults.bool(forKey: "forceTmuxMissing"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// How every tmux client in the app reaches the private server. Control-mode clients must use
/// the same values as the `TmuxClient` behind `AppState`.
struct TmuxEnvironment: Sendable {
    let tmuxPath: String
    /// The app-owned tmux.conf passed with `-f`.
    let tmuxConfPath: String
    let socketName: String

    func makeClient() -> TmuxClient {
        TmuxClient(tmuxPath: tmuxPath, configPath: tmuxConfPath, socketName: socketName)
    }
}
