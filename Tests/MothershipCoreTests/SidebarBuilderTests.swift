import Testing

@testable import MothershipCore

private func pane(
    _ session: String, project: String = "app", kind: ItemKind, name: String = "", created: Int = 1,
    dead: Bool = false, status: Int? = nil
) -> PaneInfo {
    PaneInfo(
        sessionName: session, paneID: "%1", pid: dead ? 0 : 10, created: created, isDead: dead,
        deadStatus: status, project: project, kind: kind, name: name, template: "")
}

private let vite = CommandConfig(name: "Vite", slug: "vite", run: "npm run dev", autostart: true)
private let queue = CommandConfig(name: "Queue", slug: "queue", run: "php artisan queue:work", autostart: false)
private let horizon = CommandConfig(name: "Horizon", slug: "horizon", run: "php artisan horizon", autostart: true)

private func config(_ commands: [CommandConfig]) -> MothershipConfig {
    MothershipConfig(projects: [
        ProjectConfig(
            name: "App", slug: "app", path: "/tmp/app", commands: commands,
            agents: [AgentTemplate(name: "Claude", run: "claude")])
    ])
}

struct SidebarBuilderTests {
    @Test func testCommandsListedInConfigOrderWithStatuses() -> Void {
        let panes = [
            pane("ms-app-cmd-vite", kind: .command, name: "Vite"),
            pane("ms-app-cmd-horizon", kind: .command, name: "Horizon", dead: true, status: 1),
        ]
        let sections = SidebarBuilder.build(config: config([vite, queue, horizon]), panes: panes)
        #expect(sections.count == 1)
        #expect(sections[0].path == "/tmp/app")
        #expect(sections[0].agentTemplates.count == 1)
        #expect(sections[0].commands.map(\.displayName) == ["Vite", "Queue", "Horizon"])
        #expect(sections[0].commands.map(\.status) == [.running, .notStarted, .exited(code: 1)])
        #expect(sections[0].commands[1].id == "ms-app-cmd-queue")
        #expect(sections[0].commands.allSatisfy { !$0.isOrphan })
    }

    @Test func testAgentsAndTerminalsSortedByCreation() -> Void {
        let panes = [
            pane("ms-app-agent-bbb", kind: .agent, name: "B", created: 20),
            pane("ms-app-agent-aaa", kind: .agent, name: "A", created: 20),
            pane("ms-app-agent-ccc", kind: .agent, name: "C", created: 5),
            pane("ms-app-term-zzz", kind: .terminal, name: "Z", created: 9),
            pane("ms-app-term-yyy", kind: .terminal, name: "Y", created: 3),
        ]
        let section = SidebarBuilder.build(config: config([]), panes: panes)[0]
        #expect(section.agents.map(\.id) == ["ms-app-agent-ccc", "ms-app-agent-aaa", "ms-app-agent-bbb"])
        #expect(section.terminals.map(\.id) == ["ms-app-term-yyy", "ms-app-term-zzz"])
    }

    @Test func testRemovedCommandStillRunningIsOrphan() -> Void {
        let panes = [pane("ms-app-cmd-old", kind: .command, name: "Old")]
        let commands = SidebarBuilder.build(config: config([vite]), panes: panes)[0].commands
        #expect(commands.map(\.displayName) == ["Vite", "Old"])
        #expect(commands[1].isOrphan)
        #expect(commands[1].status == .running)
        #expect(!commands[0].isOrphan)
    }

    @Test func testRemovedCommandThatIsDeadIsDropped() -> Void {
        let panes = [pane("ms-app-cmd-old", kind: .command, name: "Old", dead: true, status: 0)]
        let commands = SidebarBuilder.build(config: config([vite]), panes: panes)[0].commands
        #expect(commands.map(\.displayName) == ["Vite"])
    }

    @Test func testRemovedProjectWithLiveSessionsBecomesOrphanSection() -> Void {
        let panes = [
            pane("ms-gone-term-abc", project: "gone", kind: .terminal, name: "Shell"),
            pane("ms-gone-cmd-x", project: "gone", kind: .command, name: "X"),
            pane("ms-gone-cmd-y", project: "gone", kind: .command, name: "Y", dead: true, status: 0),
        ]
        let sections = SidebarBuilder.build(config: config([]), panes: panes)
        #expect(sections.map(\.id) == ["app", "gone"])
        let orphan = sections[1]
        #expect(orphan.name == "gone")
        #expect(orphan.path == nil)
        #expect(orphan.isOrphan)
        #expect(orphan.agentTemplates.isEmpty)
        #expect(orphan.terminals.count == 1)
        #expect(orphan.commands.map(\.id) == ["ms-gone-cmd-x"])
    }

    @Test func testOrphanProjectWithOnlyDeadCommandsIsOmitted() -> Void {
        let panes = [pane("ms-gone-cmd-y", project: "gone", kind: .command, name: "Y", dead: true, status: 0)]
        #expect(SidebarBuilder.build(config: config([]), panes: panes).map(\.id) == ["app"])
    }

    @Test func testPanesWithoutKindAreIgnored() -> Void {
        var p = pane("ms-app-term-abc", kind: .terminal)
        p.kind = nil
        #expect(SidebarBuilder.build(config: config([]), panes: [p])[0].terminals.isEmpty)
    }

    @Test func testDeadAgentStaysWithExitedStatus() -> Void {
        let panes = [pane("ms-app-agent-abc", kind: .agent, name: "Claude", dead: true, status: 0)]
        let agents = SidebarBuilder.build(config: config([]), panes: panes)[0].agents
        #expect(agents.count == 1)
        #expect(agents[0].status == .exited(code: 0))
    }

    @Test func testAutostartSkipsRunningSessionsButStartsDeadOnes() -> Void {
        let auto3 = CommandConfig(name: "Mail", slug: "mail", run: "mailpit", autostart: true)
        let panes = [
            pane("ms-app-cmd-vite", kind: .command),
            pane("ms-app-cmd-horizon", kind: .command, dead: true, status: 1),
        ]
        let result = AutostartPlanner.commandsToStart(config: config([vite, horizon, auto3]), panes: panes)
        #expect(result.map(\.command.slug) == ["horizon", "mail"])
        #expect(result.map(\.project.slug) == ["app", "app"])
    }

    @Test func testAutostartIgnoresNonAutostartCommands() -> Void {
        #expect(AutostartPlanner.commandsToStart(config: config([queue]), panes: []).isEmpty)
    }
}
