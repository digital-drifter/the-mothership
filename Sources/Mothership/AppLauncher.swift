import Foundation
import MothershipCore
import Observation

/// Runs the launch sequence once and owns what lives for the whole app run:
/// the `AppState` and the 1 s refresh loop.
@MainActor @Observable
final class AppLauncher {
    enum Phase {
        case launching
        case tmuxMissing
        case ready(AppState, TerminalSessionCache)
    }

    let options: LaunchOptions
    private(set) var phase: Phase = .launching
    /// Set once tmux is found; shared with every tmux client the app creates.
    private(set) var tmux: TmuxEnvironment?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    init(options: LaunchOptions = .current()) {
        self.options = options
    }

    /// Starts the app, or shows the missing-tmux screen. Safe to call again ("Check Again").
    func launch() async -> Void {
        guard !started else { return }
        let environment = ProcessInfo.processInfo.environment
        guard !options.forceTmuxMissing,
              let tmuxPath = TmuxLocator.find(environmentPath: environment["PATH"])
        else {
            phase = .tmuxMissing
            return
        }
        started = true

        var setupError: String?
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mothership")
        let tmuxConfURL = supportDirectory.appendingPathComponent("tmux.conf")
        do {
            _ = try TmuxConfig.install(in: supportDirectory)
        } catch {
            setupError = "Could not write \(tmuxConfURL.path): \(error.localizedDescription)"
        }

        let tmux = TmuxEnvironment(tmuxPath: tmuxPath, tmuxConfPath: tmuxConfURL.path, socketName: options.socketName)
        let state = AppState(
            tmux: tmux.makeClient(), store: ProjectStore(url: options.dataURL),
            shell: environment["SHELL"] ?? "/bin/zsh")
        let terminals = TerminalSessionCache(tmux: tmux)
        state.onRespawn = { [weak terminals] names in terminals?.reseed(names) }
        self.tmux = tmux
        phase = .ready(state, terminals)

        state.load()
        await state.refresh()
        Self.prune(terminals, to: state)
        await state.runAutostart()
        if let setupError { state.actionError = setupError }

        startRefreshLoop(state, terminals)
    }

    /// Refreshes every second; each refresh finishes before the next sleep, so they never overlap.
    private func startRefreshLoop(_ state: AppState, _ terminals: TerminalSessionCache) -> Void {
        refreshLoop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await state.refresh()
                Self.prune(terminals, to: state)
            }
        }
    }

    /// Drops terminal sessions whose items are no longer in the sidebar.
    private static func prune(_ terminals: TerminalSessionCache, to state: AppState) -> Void {
        let names = state.sections.flatMap { $0.agents + $0.commands + $0.terminals }.map(\.id)
        terminals.prune(keeping: Set(names))
    }
}
