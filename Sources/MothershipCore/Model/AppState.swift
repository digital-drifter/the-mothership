import Foundation
import Observation

@MainActor @Observable
public final class AppState {
    public private(set) var sections: [ProjectSection] = []
    public private(set) var configError: String?
    /// The last config that parsed; kept when a later edit breaks the file.
    public private(set) var config = MothershipConfig(projects: [])
    public var actionError: String?
    /// Called after a refresh with the sessions whose pane process was replaced since the last one.
    /// respawn-pane resets a pane without emitting output, so a view showing it must be re-seeded.
    @ObservationIgnored public var onRespawn: ((Set<String>) -> Void)?

    @ObservationIgnored private let tmux: TmuxCommanding
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let shell: String
    @ObservationIgnored private let homeDirectory: String
    @ObservationIgnored private let stopGracePeriod: Duration
    @ObservationIgnored private let signalProcessGroup: (Int32) -> Void
    @ObservationIgnored private let directoryExists: (String) -> Bool
    @ObservationIgnored private var panes: [PaneInfo] = []
    @ObservationIgnored private var respawns = RespawnTracker()
    /// False until a config has parsed; until then every command would look like an orphan.
    @ObservationIgnored private var hasLoadedConfig = false
    /// Names handed out by in-flight creates, so concurrent creates never pick the same number.
    @ObservationIgnored private var pendingNames: [String: Set<String>] = [:]

    public init(
        tmux: TmuxCommanding, configURL: URL, shell: String, homeDirectory: String,
        stopGracePeriod: Duration = .seconds(5),
        signalProcessGroup: @escaping (Int32) -> Void = { _ = kill(-$0, SIGTERM) },
        directoryExists: @escaping (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) {
        self.tmux = tmux
        self.configURL = configURL
        self.shell = shell
        self.homeDirectory = homeDirectory
        self.stopGracePeriod = stopGracePeriod
        self.signalProcessGroup = signalProcessGroup
        self.directoryExists = directoryExists
    }

    // MARK: - Config and polling

    public func reloadConfig() -> Void {
        let text: String
        do {
            text = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            configError = "Config file not found: \(configURL.path)"
            return
        }
        do {
            config = try ConfigLoader.parse(text, homeDirectory: homeDirectory)
            hasLoadedConfig = true
            configError = nil
            rebuildSections()
        } catch {
            configError = String(describing: error)
        }
    }

    public func refresh() async -> Void {
        do {
            panes = await removingDeadOrphanCommands(try await tmux.listPanes())
            rebuildSections()
            let respawned = respawns.update(panes)
            if !respawned.isEmpty { onRespawn?(respawned) }
        } catch {
            report(error)
        }
    }

    public func runAutostart() async -> Void {
        await refresh()
        for entry in AutostartPlanner.commandsToStart(config: config, panes: panes) {
            await start(commandSlug: entry.command.slug, projectSlug: entry.project.slug)
        }
    }

    // MARK: - Actions

    public func start(commandSlug: String, projectSlug: String) async -> Void {
        guard let project = config.projects.first(where: { $0.slug == projectSlug }),
              let command = project.commands.first(where: { $0.slug == commandSlug })
        else {
            actionError = "Unknown command: \(projectSlug)/\(commandSlug)"
            return
        }
        guard folderExists(project) else { return }
        let session = SessionName.make(projectSlug: projectSlug, kind: .command, id: commandSlug)
        do {
            if let existing = panes.first(where: { $0.sessionName == session }) {
                if existing.isDead {
                    try await tmux.respawn(session: session, directory: project.path, command: [shell, "-lc", command.run])
                }
            } else {
                try await tmux.newSession(
                    name: session, directory: project.path, command: [shell, "-lc", command.run],
                    metadata: SessionMetadata(project: projectSlug, kind: .command, name: command.name, template: ""))
            }
        } catch {
            report(error)
        }
        await refresh()
    }

    public func stop(sessionName: String) async -> Void {
        guard knows(sessionName) else { return }
        do {
            // The process being stopped; a process started during the grace period is left alone.
            let target = try await tmux.listPanes()
                .first { $0.sessionName == sessionName && !$0.isDead && $0.pid > 0 }?.pid
            try await tmux.interrupt(session: sessionName)
            try? await Task.sleep(for: stopGracePeriod)
            let current = try await tmux.listPanes()
            if let target,
               current.contains(where: { $0.sessionName == sessionName && !$0.isDead && $0.pid == target }) {
                signalProcessGroup(target)
            }
        } catch {
            report(error)
        }
        await refresh()
    }

    public func restart(sessionName: String) async -> Void {
        await respawn(sessionName)
    }

    public func relaunch(sessionName: String) async -> Void {
        await respawn(sessionName)
    }

    public func close(sessionName: String) async -> Void {
        guard knows(sessionName) else { return }
        do {
            try await tmux.killSession(sessionName)
        } catch {
            report(error)
        }
        await refresh()
    }

    public func rename(sessionName: String, to name: String) async -> Void {
        guard knows(sessionName) else { return }
        do {
            try await tmux.setName(session: sessionName, name: DisplayName.clean(name))
        } catch {
            report(error)
        }
        await refresh()
    }

    @discardableResult
    public func newTerminal(projectSlug: String) async -> String? {
        await create(projectSlug: projectSlug, kind: .terminal, prefix: "Terminal", template: "", run: nil)
    }

    @discardableResult
    public func newAgent(projectSlug: String, templateName: String) async -> String? {
        guard let template = config.projects.first(where: { $0.slug == projectSlug })?
            .agents.first(where: { $0.name == templateName })
        else {
            actionError = "Unknown agent template: \(templateName)"
            return nil
        }
        return await create(projectSlug: projectSlug, kind: .agent, prefix: template.name, template: template.name, run: template.run)
    }

    /// Kills the private tmux server. Returns false (and sets `actionError`) when that failed.
    @discardableResult
    public func stopAll() async -> Bool {
        var stopped = true
        do {
            try await tmux.killServer()
        } catch {
            report(error)
            stopped = false
        }
        await refresh()
        return stopped
    }

    // MARK: - Helpers

    private func create(projectSlug: String, kind: ItemKind, prefix: String, template: String, run: String?) async -> String? {
        guard let project = config.projects.first(where: { $0.slug == projectSlug }) else {
            actionError = "Unknown project: \(projectSlug)"
            return nil
        }
        guard folderExists(project) else { return nil }
        let name = "\(prefix) \(nextNumber(prefix: prefix, in: projectSlug))"
        pendingNames[projectSlug, default: []].insert(name)
        defer { pendingNames[projectSlug]?.remove(name) }
        let session = SessionName.make(projectSlug: projectSlug, kind: kind, id: SessionName.randomID())
        let argv = run.map { [shell, "-lc", $0] } ?? [shell, "-l"]
        var result: String?
        do {
            try await tmux.newSession(
                name: session, directory: project.path, command: argv,
                metadata: SessionMetadata(project: projectSlug, kind: kind, name: name, template: template))
            result = session
        } catch {
            report(error)
        }
        await refresh()
        return result
    }

    private func nextNumber(prefix: String, in projectSlug: String) -> Int {
        let existing = sections.first(where: { $0.id == projectSlug })
            .map { ($0.agents + $0.terminals).map(\.displayName) } ?? []
        let highest = (existing + Array(pendingNames[projectSlug] ?? [])).compactMap { name -> Int? in
            guard name.hasPrefix(prefix + " ") else { return nil }
            return Int(name.dropFirst(prefix.count + 1))
        }.max() ?? 0
        return highest + 1
    }

    private func respawn(_ sessionName: String) async -> Void {
        guard knows(sessionName) else { return }
        if let slug = panes.first(where: { $0.sessionName == sessionName })?.project
            ?? sections.first(where: { ($0.agents + $0.commands + $0.terminals).contains { $0.id == sessionName } })?.id,
           let project = config.projects.first(where: { $0.slug == slug }),
           !folderExists(project) {
            return
        }
        do {
            if let (project, command) = configuredCommand(sessionName) {
                // Commands run what the config says now; agents and terminals rerun their original command.
                try await tmux.respawn(session: sessionName, directory: project.path, command: [shell, "-lc", command.run])
            } else {
                try await tmux.respawn(session: sessionName)
            }
        } catch {
            report(error)
        }
        await refresh()
    }

    /// Kills command sessions that are dead and no longer in the config. The sidebar hides them anyway;
    /// left alone they would pile up, and re-adding the command would show their old output.
    /// A failed kill is reported and the pane kept, so the refresh itself still goes through.
    private func removingDeadOrphanCommands(_ panes: [PaneInfo]) async -> [PaneInfo] {
        guard hasLoadedConfig else { return panes }
        var kept: [PaneInfo] = []
        for pane in panes {
            guard pane.kind == .command, pane.isDead, configuredCommand(pane.sessionName) == nil else {
                kept.append(pane)
                continue
            }
            do {
                try await tmux.killSession(pane.sessionName)
            } catch {
                report(error)
                kept.append(pane)
            }
        }
        return kept
    }

    /// The config entry of a command session; nil for agents, terminals and orphan commands.
    private func configuredCommand(_ sessionName: String) -> (ProjectConfig, CommandConfig)? {
        for project in config.projects {
            if let command = project.commands.first(where: {
                SessionName.make(projectSlug: project.slug, kind: .command, id: $0.slug) == sessionName
            }) {
                return (project, command)
            }
        }
        return nil
    }

    private func knows(_ sessionName: String) -> Bool {
        let known = panes.contains { $0.sessionName == sessionName }
            || sections.contains { ($0.agents + $0.commands + $0.terminals).contains { $0.id == sessionName } }
        if !known { actionError = "Unknown session: \(sessionName)" }
        return known
    }

    private func folderExists(_ project: ProjectConfig) -> Bool {
        guard directoryExists(project.path) else {
            actionError = "Folder not found: \(project.path)"
            return false
        }
        return true
    }

    private func report(_ error: Error) -> Void {
        if let tmuxError = error as? TmuxError {
            actionError = tmuxError.message.isEmpty ? "tmux failed (exit \(tmuxError.exitCode))" : tmuxError.message
        } else {
            actionError = String(describing: error)
        }
    }

    private func rebuildSections() -> Void {
        sections = SidebarBuilder.build(config: config, panes: panes)
    }
}
