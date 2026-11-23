import Foundation
import Observation

@MainActor @Observable
public final class AppState {
    public private(set) var sections: [ProjectSection] = []
    public private(set) var configError: String?
    public var actionError: String?

    @ObservationIgnored private let tmux: TmuxCommanding
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let shell: String
    @ObservationIgnored private let homeDirectory: String
    @ObservationIgnored private let stopGracePeriod: Duration
    @ObservationIgnored private let signalProcessGroup: (Int32) -> Void
    @ObservationIgnored private let directoryExists: (String) -> Bool
    @ObservationIgnored private var config = MothershipConfig(projects: [])
    @ObservationIgnored private var panes: [PaneInfo] = []

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
            configError = nil
            rebuildSections()
        } catch {
            configError = String(describing: error)
        }
    }

    public func refresh() async -> Void {
        do {
            panes = try await tmux.listPanes()
            rebuildSections()
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
            if panes.contains(where: { $0.sessionName == session }) {
                try await tmux.respawn(session: session)
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
            try await tmux.interrupt(session: sessionName)
            try? await Task.sleep(for: stopGracePeriod)
            let current = try await tmux.listPanes()
            if let pane = current.first(where: { $0.sessionName == sessionName }), !pane.isDead, pane.pid > 0 {
                signalProcessGroup(pane.pid)
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
            try await tmux.setName(session: sessionName, name: name)
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

    public func stopAll() async -> Void {
        do {
            try await tmux.killServer()
        } catch {
            report(error)
        }
        await refresh()
    }

    // MARK: - Helpers

    private func create(projectSlug: String, kind: ItemKind, prefix: String, template: String, run: String?) async -> String? {
        guard let project = config.projects.first(where: { $0.slug == projectSlug }) else {
            actionError = "Unknown project: \(projectSlug)"
            return nil
        }
        guard folderExists(project) else { return nil }
        let name = "\(prefix) \(nextNumber(prefix: prefix, in: projectSlug))"
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
        guard let section = sections.first(where: { $0.id == projectSlug }) else { return 1 }
        let highest = (section.agents + section.terminals).compactMap { item -> Int? in
            guard item.displayName.hasPrefix(prefix + " ") else { return nil }
            return Int(item.displayName.dropFirst(prefix.count + 1))
        }.max() ?? 0
        return highest + 1
    }

    private func respawn(_ sessionName: String) async -> Void {
        guard knows(sessionName) else { return }
        do {
            try await tmux.respawn(session: sessionName)
        } catch {
            report(error)
        }
        await refresh()
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
