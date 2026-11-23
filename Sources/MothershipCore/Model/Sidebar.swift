import Foundation

public enum ItemStatus: Equatable, Sendable {
    case notStarted
    case running
    case exited(code: Int)
}

public struct SidebarItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: ItemKind
    public var displayName: String
    public var status: ItemStatus
    public var isOrphan: Bool

    public init(id: String, kind: ItemKind, displayName: String, status: ItemStatus, isOrphan: Bool) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.status = status
        self.isOrphan = isOrphan
    }
}

public struct ProjectSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String?
    public var isOrphan: Bool
    public var agentTemplates: [AgentTemplate]
    public var agents: [SidebarItem]
    public var commands: [SidebarItem]
    public var terminals: [SidebarItem]

    public init(
        id: String, name: String, path: String?, isOrphan: Bool, agentTemplates: [AgentTemplate],
        agents: [SidebarItem], commands: [SidebarItem], terminals: [SidebarItem]
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isOrphan = isOrphan
        self.agentTemplates = agentTemplates
        self.agents = agents
        self.commands = commands
        self.terminals = terminals
    }
}

public enum SidebarBuilder {
    public static func build(config: MothershipConfig, panes: [PaneInfo]) -> [ProjectSection] {
        let known = panes.filter { $0.kind != nil }
        var sections = config.projects.map { project -> ProjectSection in
            let projectPanes = known.filter { $0.project == project.slug }
            return section(
                id: project.slug, name: project.name, path: project.path, isOrphan: false,
                templates: project.agents, configCommands: project.commands, panes: projectPanes)
        }

        let configSlugs = Set(config.projects.map(\.slug))
        var orphanSlugs: [String] = []
        for pane in known where !configSlugs.contains(pane.project) && !orphanSlugs.contains(pane.project) {
            orphanSlugs.append(pane.project)
        }
        for slug in orphanSlugs {
            let orphan = section(
                id: slug, name: slug, path: nil, isOrphan: true, templates: [], configCommands: [],
                panes: known.filter { $0.project == slug })
            if !(orphan.agents.isEmpty && orphan.commands.isEmpty && orphan.terminals.isEmpty) {
                sections.append(orphan)
            }
        }
        return sections
    }

    private static func section(
        id: String, name: String, path: String?, isOrphan: Bool, templates: [AgentTemplate],
        configCommands: [CommandConfig], panes: [PaneInfo]
    ) -> ProjectSection {
        var commands: [SidebarItem] = configCommands.map { command in
            let sessionName = SessionName.make(projectSlug: id, kind: .command, id: command.slug)
            let pane = panes.first { $0.kind == .command && $0.sessionName == sessionName }
            return SidebarItem(
                id: sessionName, kind: .command, displayName: pane?.name ?? command.name,
                status: status(of: pane), isOrphan: false)
        }
        let configIDs = Set(commands.map(\.id))
        commands += panes.filter { $0.kind == .command && !configIDs.contains($0.sessionName) && !$0.isDead }
            .sorted(by: ordered)
            .map { item(from: $0, orphan: true) }

        return ProjectSection(
            id: id, name: name, path: path, isOrphan: isOrphan, agentTemplates: templates,
            agents: items(of: .agent, in: panes), commands: commands, terminals: items(of: .terminal, in: panes))
    }

    private static func items(of kind: ItemKind, in panes: [PaneInfo]) -> [SidebarItem] {
        panes.filter { $0.kind == kind }.sorted(by: ordered).map { item(from: $0, orphan: false) }
    }

    private static func ordered(_ a: PaneInfo, _ b: PaneInfo) -> Bool {
        a.created != b.created ? a.created < b.created : a.sessionName < b.sessionName
    }

    private static func item(from pane: PaneInfo, orphan: Bool) -> SidebarItem {
        SidebarItem(
            id: pane.sessionName, kind: pane.kind ?? .terminal, displayName: pane.name,
            status: status(of: pane), isOrphan: orphan)
    }

    private static func status(of pane: PaneInfo?) -> ItemStatus {
        guard let pane else { return .notStarted }
        return pane.isDead ? .exited(code: pane.deadStatus ?? 0) : .running
    }
}

public enum AutostartPlanner {
    public static func commandsToStart(
        config: MothershipConfig, panes: [PaneInfo]
    ) -> [(project: ProjectConfig, command: CommandConfig)] {
        let existing = Set(panes.map(\.sessionName))
        return config.projects.flatMap { project in
            project.commands
                .filter { $0.autostart }
                .filter { !existing.contains(SessionName.make(projectSlug: project.slug, kind: .command, id: $0.slug)) }
                .map { (project: project, command: $0) }
        }
    }
}
