import Foundation
import Observation

@MainActor @Observable
public final class AppState {
    public private(set) var sections: [ProjectSection] = []
    /// The stored projects and agent templates, as last loaded.
    public private(set) var config = MothershipConfig.empty
    public var actionError: String?
    /// Called after a refresh with the sessions whose pane process was replaced since the last one.
    /// respawn-pane resets a pane without emitting output, so a view showing it must be re-seeded.
    @ObservationIgnored public var onRespawn: ((Set<String>) -> Void)?

    @ObservationIgnored private let tmux: TmuxCommanding
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let shell: String
    @ObservationIgnored private let stopGracePeriod: Duration
    @ObservationIgnored private let signalProcessGroup: (Int32) -> Void
    @ObservationIgnored private let directoryExists: (String) -> Bool
    @ObservationIgnored private var panes: [PaneInfo] = []
    @ObservationIgnored private var respawns = RespawnTracker()
    /// False until the store has been loaded; until then every command would look like an orphan.
    @ObservationIgnored private var hasLoadedConfig = false
    /// False when an unreadable file could not be moved aside; saving would overwrite it.
    @ObservationIgnored private var canSave = true
    /// Refreshes overlap (the 1 s loop and actions); a list older than the one shown is discarded.
    @ObservationIgnored private var startedRefreshes = 0
    @ObservationIgnored private var appliedRefresh = 0
    /// Orphan command sessions with a kill in flight, so overlapping refreshes kill each only once.
    @ObservationIgnored private var killingOrphans: Set<String> = []
    /// Names handed out by in-flight creates, so concurrent creates never pick the same number.
    @ObservationIgnored private var pendingNames: [String: Set<String>] = [:]

    public init(
        tmux: TmuxCommanding, store: ProjectStore, shell: String,
        stopGracePeriod: Duration = .seconds(5),
        signalProcessGroup: @escaping (Int32) -> Void = { _ = kill(-$0, SIGTERM) },
        directoryExists: @escaping (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) {
        self.tmux = tmux
        self.store = store
        self.shell = shell
        self.stopGracePeriod = stopGracePeriod
        self.signalProcessGroup = signalProcessGroup
        self.directoryExists = directoryExists
    }

    // MARK: - Config and polling

    /// The agent templates offered in every project's New Agent menu.
    public var agents: [AgentTemplate] { config.agents }

    /// Reads the store. An unreadable file shows its warning as the action error.
    public func load() -> Void {
        let loaded = store.load()
        config = loaded.config
        hasLoadedConfig = true
        canSave = loaded.canSave
        if let warning = loaded.warning { actionError = warning }
        rebuildSections()
    }

    public func refresh() async -> Void {
        startedRefreshes += 1
        let generation = startedRefreshes
        let listed: [PaneInfo]
        do {
            listed = try await tmux.listPanes()
        } catch {
            report(error)
            return
        }
        guard generation > appliedRefresh else { return }
        appliedRefresh = generation
        panes = listed
        rebuildSections()
        let respawned = respawns.update(panes)
        if !respawned.isEmpty { onRespawn?(respawned) }
        await killDeadOrphanCommands(listed)
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
        guard folderExists(project), let directory = commandDirectory(project, command) else { return }
        let session = SessionName.make(projectSlug: projectSlug, kind: .command, id: commandSlug)
        do {
            if let existing = panes.first(where: { $0.sessionName == session }) {
                if existing.isDead {
                    try await tmux.respawn(session: session, directory: directory, command: [shell, "-lc", command.run])
                }
            } else {
                try await tmux.newSession(
                    name: session, directory: directory, command: [shell, "-lc", command.run],
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
        guard let template = config.agents.first(where: { $0.name == templateName }) else {
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
                guard let directory = commandDirectory(project, command) else { return }
                try await tmux.respawn(session: sessionName, directory: directory, command: [shell, "-lc", command.run])
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
    private func killDeadOrphanCommands(_ panes: [PaneInfo]) async -> Void {
        guard hasLoadedConfig else { return }
        let orphans = panes.filter {
            $0.kind == .command && $0.isDead && configuredCommand($0.sessionName) == nil
                && !killingOrphans.contains($0.sessionName)
        }
        for pane in orphans {
            killingOrphans.insert(pane.sessionName)
            defer { killingOrphans.remove(pane.sessionName) }
            do {
                try await tmux.killSession(pane.sessionName)
            } catch {
                report(error)
            }
        }
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

    /// The command's working directory, or nil (with `actionError` set) when it is missing.
    private func commandDirectory(_ project: ProjectConfig, _ command: CommandConfig) -> String? {
        let directory = project.workingDirectory(for: command)
        if directory != project.path, !directoryExists(directory) {
            actionError = "Folder not found: \(directory)"
            return nil
        }
        return directory
    }

    private func report(_ error: Error) -> Void {
        if let tmuxError = error as? TmuxError {
            actionError = tmuxError.message.isEmpty ? "tmux failed (exit \(tmuxError.exitCode))" : tmuxError.message
        } else {
            actionError = String(describing: error)
        }
    }

    /// Kills every session, carrying on past failures. Sessions that are already gone count as killed;
    /// the first other error is reported.
    private func killSessions(_ sessions: [String]) async -> Void {
        var firstError: Error?
        for session in sessions {
            do {
                try await tmux.killSessionIfPresent(session)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { report(firstError) }
    }

    private func rebuildSections() -> Void {
        sections = SidebarBuilder.build(config: config, panes: panes)
    }
}

// MARK: - Editing projects, commands and agents

extension AppState {
    /// Adds the folder as a project, or returns the slug of the project already using it.
    /// Returns nil when the config could not be saved.
    @discardableResult
    public func addProject(path: String) -> String? {
        let standardized = Self.standardized(path)
        if let existing = config.projects.first(where: { $0.path == standardized }) { return existing.slug }
        let name = DisplayName.clean(URL(fileURLWithPath: standardized).lastPathComponent)
        let slug = Slug.unique(name, fallback: "project", taken: Set(config.projects.map(\.slug)))
        let added = commit { $0.projects.append(ProjectConfig(slug: slug, name: name, path: standardized, commands: [])) }
        return added ? slug : nil
    }

    public func renameProject(slug: String, to name: String) -> Void {
        let cleaned = Self.trimmed(name)
        guard !cleaned.isEmpty else { return }
        commit { config in
            guard let index = config.projects.firstIndex(where: { $0.slug == slug }) else { return }
            config.projects[index].name = cleaned
        }
    }

    public func changeFolder(projectSlug: String, to path: String) -> Void {
        let standardized = Self.standardized(path)
        commit { config in
            guard let index = config.projects.firstIndex(where: { $0.slug == projectSlug }) else { return }
            config.projects[index].path = standardized
        }
    }

    /// Live sessions of the project, for the confirmation before removing it.
    public func runningSessionCount(projectSlug: String) -> Int {
        panes.filter { $0.project == projectSlug && !$0.isDead }.count
    }

    /// Forgets the project, then kills all of its sessions.
    public func removeProject(slug: String) async -> Void {
        guard commit({ $0.projects.removeAll { $0.slug == slug } }) else { return }
        do {
            await killSessions(try await tmux.listPanes().filter { $0.project == slug }.map(\.sessionName))
        } catch {
            report(error)
        }
        await refresh()
    }

    private static func storedDirectory(_ directory: String) -> String? {
        let cleaned = trimmed(directory)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The message to show next to the form, or nil when the command can be saved.
    public func validateCommand(projectSlug: String, name: String, run: String, directory: String, editing commandSlug: String?) -> String? {
        let cleaned = Self.trimmed(name)
        if cleaned.isEmpty { return "Name can't be empty." }
        let others = config.projects.first { $0.slug == projectSlug }?.commands.filter { $0.slug != commandSlug } ?? []
        if others.contains(where: { $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame }) {
            return "A command named \u{201C}\(cleaned)\u{201D} already exists in this project."
        }
        if run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Command can't be empty." }
        if let project = config.projects.first(where: { $0.slug == projectSlug }),
           !Self.trimmed(directory).isEmpty {
            let resolved = project.workingDirectory(
                for: CommandConfig(slug: "", name: "", run: "", autostart: false, directory: directory))
            if resolved != project.path, !directoryExists(resolved) { return "Folder not found: \(resolved)" }
        }
        return nil
    }

    /// Saves the command and starts it. Returns its session name.
    @discardableResult
    public func addCommand(projectSlug: String, name: String, run: String, directory: String, autostart: Bool) async -> String? {
        if let problem = validateCommand(projectSlug: projectSlug, name: name, run: run, directory: directory, editing: nil) {
            actionError = problem
            return nil
        }
        guard let project = config.projects.first(where: { $0.slug == projectSlug }) else {
            actionError = "Unknown project: \(projectSlug)"
            return nil
        }
        let cleaned = Self.trimmed(name)
        let slug = Slug.unique(cleaned, fallback: "command", taken: Set(project.commands.map(\.slug)))
        let command = CommandConfig(
            slug: slug, name: cleaned, run: run.trimmingCharacters(in: .whitespacesAndNewlines), autostart: autostart,
            directory: Self.storedDirectory(directory))
        guard commit({ config in
            guard let index = config.projects.firstIndex(where: { $0.slug == projectSlug }) else { return }
            config.projects[index].commands.append(command)
        }) else { return nil }
        await start(commandSlug: slug, projectSlug: projectSlug)
        return SessionName.make(projectSlug: projectSlug, kind: .command, id: slug)
    }

    /// Saves the changes. A running session picks up the new name at once; a new run line applies on the next start.
    public func editCommand(projectSlug: String, commandSlug: String, name: String, run: String, directory: String, autostart: Bool) async -> Void {
        if let problem = validateCommand(projectSlug: projectSlug, name: name, run: run, directory: directory, editing: commandSlug) {
            actionError = problem
            return
        }
        let cleaned = Self.trimmed(name)
        let trimmedRun = run.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit({ config in
            guard let index = config.projects.firstIndex(where: { $0.slug == projectSlug }),
                  let at = config.projects[index].commands.firstIndex(where: { $0.slug == commandSlug })
            else { return }
            config.projects[index].commands[at] = CommandConfig(
                slug: commandSlug, name: cleaned, run: trimmedRun, autostart: autostart,
                directory: Self.storedDirectory(directory))
        }) else { return }
        let session = SessionName.make(projectSlug: projectSlug, kind: .command, id: commandSlug)
        if panes.contains(where: { $0.sessionName == session }) {
            do {
                try await tmux.setName(session: session, name: cleaned)
            } catch {
                report(error)
            }
        }
        await refresh()
    }

    /// Forgets the command and kills its session if it has one.
    public func deleteCommand(projectSlug: String, commandSlug: String) async -> Void {
        guard commit({ config in
            guard let index = config.projects.firstIndex(where: { $0.slug == projectSlug }) else { return }
            config.projects[index].commands.removeAll { $0.slug == commandSlug }
        }) else { return }
        let session = SessionName.make(projectSlug: projectSlug, kind: .command, id: commandSlug)
        do {
            if try await tmux.listPanes().contains(where: { $0.sessionName == session }) {
                await killSessions([session])
            }
        } catch {
            report(error)
        }
        await refresh()
    }

    public func validateAgentTemplate(name: String, run: String) -> String? {
        let cleaned = Self.trimmed(name)
        if cleaned.isEmpty { return "Name can't be empty." }
        if config.agents.contains(where: { $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame }) {
            return "An agent named \u{201C}\(cleaned)\u{201D} is already in the list."
        }
        if run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Command can't be empty." }
        return nil
    }

    public func addAgentTemplate(name: String, run: String) -> Void {
        if let problem = validateAgentTemplate(name: name, run: run) {
            actionError = problem
            return
        }
        let template = AgentTemplate(name: Self.trimmed(name), run: run.trimmingCharacters(in: .whitespacesAndNewlines))
        commit { $0.agents.append(template) }
    }

    public func removeAgentTemplate(name: String) -> Void {
        commit { $0.agents.removeAll { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
    }

    /// Starts an agent from a one-off command, without adding it to the list. Returns its session name.
    @discardableResult
    public func newCustomAgent(projectSlug: String, name: String, run: String) async -> String? {
        let cleaned = Self.trimmed(name)
        let command = run.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !command.isEmpty else {
            actionError = cleaned.isEmpty ? "Name can't be empty." : "Command can't be empty."
            return nil
        }
        return await create(projectSlug: projectSlug, kind: .agent, prefix: cleaned, template: cleaned, run: command)
    }

    // MARK: - Helpers

    /// Applies `change` to a copy of the config and saves it; the shown config only changes once the save worked.
    @discardableResult
    private func commit(_ change: (inout MothershipConfig) -> Void) -> Bool {
        guard canSave else {
            actionError = "Changes can't be saved until the unreadable projects.json is fixed or removed."
            return false
        }
        var copy = config
        change(&copy)
        do {
            try store.save(copy)
        } catch {
            actionError = "Couldn't save projects.json: \(error.localizedDescription)"
            return false
        }
        config = copy
        rebuildSections()
        return true
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func trimmed(_ name: String) -> String {
        DisplayName.clean(name).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
