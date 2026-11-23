import Foundation
@testable import MothershipCore

let validConfig = MothershipConfig(
    version: 1,
    agents: [AgentTemplate(name: "Claude", run: "claude")],
    projects: [
        ProjectConfig(
            slug: "es", name: "ES", path: "/Users/test/Code/es",
            commands: [
                CommandConfig(slug: "vite", name: "Vite", run: "npm run dev", autostart: true),
                CommandConfig(slug: "queue", name: "Queue", run: "php artisan queue:work", autostart: false),
            ])
    ])

final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [Int32] = []
    func add(_ pid: Int32) -> Void { lock.lock(); pids.append(pid); lock.unlock() }
    var all: [Int32] { lock.lock(); defer { lock.unlock() }; return pids }
}

func makePane(
    _ session: String, pid: Int32 = 100, dead: Bool = false, kind: ItemKind, name: String, template: String = "",
    created: Int = 1, project: String = "es"
) -> PaneInfo {
    PaneInfo(
        sessionName: session, paneID: "%1", pid: dead ? 0 : pid, created: created, isDead: dead,
        deadStatus: dead ? 1 : nil, project: project, kind: kind, name: name, template: template)
}

/// A state backed by a temp store holding `config`; loaded unless `load` is false.
@MainActor
func makeState(
    config: MothershipConfig = validConfig, load: Bool = true, tmux: FakeTmux, signals: Signals = Signals(),
    folderOK: Bool = true
) throws -> (AppState, ProjectStore) {
    let store = ProjectStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-\(UUID().uuidString)/projects.json"))
    try store.save(config)
    let state = AppState(
        tmux: tmux, store: store, shell: "/bin/zsh",
        stopGracePeriod: .milliseconds(10), signalProcessGroup: { signals.add($0) },
        directoryExists: { _ in folderOK })
    if load { state.load() }
    return (state, store)
}
