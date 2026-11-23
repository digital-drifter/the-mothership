import Foundation
import Testing
@testable import MothershipCore

private let validYAML = """
projects:
  - name: ES
    path: ~/Code/es
    commands:
      - name: Vite
        run: npm run dev
        autostart: true
      - name: Queue
        run: php artisan queue:work
    agents:
      - name: Claude
        run: claude
"""

private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [Int32] = []
    func add(_ pid: Int32) -> Void { lock.lock(); pids.append(pid); lock.unlock() }
    var all: [Int32] { lock.lock(); defer { lock.unlock() }; return pids }
}

private func pane(
    _ session: String, pid: Int32 = 100, dead: Bool = false, kind: ItemKind, name: String, template: String = "", created: Int = 1
) -> PaneInfo {
    PaneInfo(
        sessionName: session, paneID: "%1", pid: dead ? 0 : pid, created: created, isDead: dead,
        deadStatus: dead ? 1 : nil, project: "es", kind: kind, name: name, template: template)
}

@MainActor
private func makeState(
    yaml: String? = validYAML, tmux: FakeTmux, signals: Signals = Signals(), folderOK: Bool = true
) throws -> (AppState, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID().uuidString).yml")
    if let yaml { try yaml.write(to: url, atomically: true, encoding: .utf8) }
    let state = AppState(
        tmux: tmux, configURL: url, shell: "/bin/zsh", homeDirectory: "/Users/test",
        stopGracePeriod: .milliseconds(10), signalProcessGroup: { signals.add($0) },
        directoryExists: { _ in folderOK })
    state.reloadConfig()
    return (state, url)
}

@Suite @MainActor struct AppStateTests {
    @Test func testReloadKeepsLastGoodConfigOnParseError() throws {
        let (state, url) = try makeState(tmux: FakeTmux())
        let before = state.sections
        #expect(before.count == 1)
        try "projects: [: nope".write(to: url, atomically: true, encoding: .utf8)
        state.reloadConfig()
        #expect(state.configError != nil)
        #expect(state.sections == before)
        try validYAML.write(to: url, atomically: true, encoding: .utf8)
        state.reloadConfig()
        #expect(state.configError == nil)
    }

    @Test func testReloadExposesParsedConfigForDisplay() throws {
        let (state, _) = try makeState(tmux: FakeTmux())
        #expect(state.config.projects.first?.commands.map(\.run) == ["npm run dev", "php artisan queue:work"])
    }

    @Test func testReloadWithDeletedFileSetsError() throws {
        let (state, url) = try makeState(tmux: FakeTmux())
        try FileManager.default.removeItem(at: url)
        state.reloadConfig()
        #expect(state.configError == "Config file not found: \(url.path)")
        #expect(state.sections.count == 1)
    }

    @Test func testStartNewCommandCallsNewSessionWithShellArgv() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        await state.start(commandSlug: "vite", projectSlug: "es")
        let calls = await fake.calls
        let create = try #require(calls.first { $0.first == "new-session" })
        #expect(create.contains("ms-es-cmd-vite"))
        let c = try #require(create.firstIndex(of: "-c"))
        #expect(create[c + 1] == "/Users/test/Code/es")
        let s = try #require(create.firstIndex(of: "/bin/zsh"))
        #expect(Array(create[s...].prefix(3)) == ["/bin/zsh", "-lc", "npm run dev"])
        #expect(create.contains("@ms_kind"))
        let k = try #require(create.firstIndex(of: "@ms_kind"))
        #expect(create[k + 1] == "cmd")
        #expect(state.actionError == nil)
    }

    @Test func testStartDeadCommandRespawns() async throws {
        let fake = FakeTmux(panes: [pane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.start(commandSlug: "vite", projectSlug: "es")
        let calls = await fake.calls
        #expect(calls.contains([
            "respawn-pane", "-k", "-c", "/Users/test/Code/es", "-t", "ms-es-cmd-vite", "/bin/zsh", "-lc", "npm run dev",
        ]))
        #expect(!calls.contains { $0.first == "new-session" })
    }

    @Test func testRefreshReportsRespawnedSessions() async throws -> Void {
        let fake = FakeTmux()
        await fake.script([
            [pane("ms-es-cmd-vite", pid: 10, kind: .command, name: "Vite")],
            [pane("ms-es-cmd-vite", pid: 11, kind: .command, name: "Vite")],
        ])
        let (state, _) = try makeState(tmux: fake)
        var reported: [Set<String>] = []
        state.onRespawn = { reported.append($0) }
        await state.refresh()
        await state.refresh()
        #expect(reported == [["ms-es-cmd-vite"]])
    }

    @Test func testStartInMissingFolderSetsErrorAndRunsNothing() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake, folderOK: false)
        await state.start(commandSlug: "vite", projectSlug: "es")
        #expect(state.actionError == "Folder not found: /Users/test/Code/es")
        #expect(await fake.calls.isEmpty)
    }

    @Test func testStopSignalsProcessGroupWhenPaneOutlivesGrace() async throws {
        let live = pane("ms-es-cmd-vite", pid: 4242, kind: .command, name: "Vite")
        let fake = FakeTmux(panes: [live])
        let signals = Signals()
        let (state, _) = try makeState(tmux: fake, signals: signals)
        await state.refresh()
        await state.stop(sessionName: "ms-es-cmd-vite")
        #expect(signals.all == [4242])
        #expect(await fake.calls.contains(["send-keys", "-t", "ms-es-cmd-vite", "C-c"]))
    }

    @Test func testStopDoesNotSignalWhenPaneDiesInTime() async throws {
        let live = pane("ms-es-cmd-vite", pid: 4242, kind: .command, name: "Vite")
        let dead = pane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")
        let fake = FakeTmux()
        await fake.script([[live], [live], [dead]])
        let signals = Signals()
        let (state, _) = try makeState(tmux: fake, signals: signals)
        await state.refresh()
        await state.stop(sessionName: "ms-es-cmd-vite")
        #expect(signals.all.isEmpty)
    }

    @Test func testStopDoesNotSignalACommandRestartedDuringGrace() async throws -> Void {
        let live = pane("ms-es-cmd-vite", pid: 4242, kind: .command, name: "Vite")
        let restarted = pane("ms-es-cmd-vite", pid: 5555, kind: .command, name: "Vite")
        let fake = FakeTmux()
        await fake.script([[live], [live], [restarted]])
        let signals = Signals()
        let (state, _) = try makeState(tmux: fake, signals: signals)
        await state.refresh()
        await state.stop(sessionName: "ms-es-cmd-vite")
        #expect(signals.all.isEmpty)
    }

    @Test func testNewTerminalNumbersAfterHighestExisting() async throws {
        let fake = FakeTmux(panes: [
            pane("ms-es-term-aaaaaa", kind: .terminal, name: "Terminal 1", created: 1),
            pane("ms-es-term-bbbbbb", kind: .terminal, name: "Terminal 3", created: 2),
        ])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        let session = try #require(await state.newTerminal(projectSlug: "es"))
        #expect(session.hasPrefix("ms-es-term-"))
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        #expect(create.contains("Terminal 4"))
        let s = try #require(create.firstIndex(of: "/bin/zsh"))
        #expect(Array(create[s...].prefix(2)) == ["/bin/zsh", "-l"])
    }

    @Test func testNewAgentUsesTemplateRunAndName() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        let session = try #require(await state.newAgent(projectSlug: "es", templateName: "Claude"))
        #expect(session.hasPrefix("ms-es-agent-"))
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let s = try #require(create.firstIndex(of: "/bin/zsh"))
        #expect(Array(create[s...].prefix(3)) == ["/bin/zsh", "-lc", "claude"])
        let n = try #require(create.firstIndex(of: "@ms_name"))
        #expect(create[n + 1] == "Claude 1")
        let t = try #require(create.firstIndex(of: "@ms_template"))
        #expect(create[t + 1] == "Claude")
    }

    @Test func testRunAutostartStartsOnlyPlannedCommands() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        await state.runAutostart()
        let creates = await fake.calls.filter { $0.first == "new-session" }
        #expect(creates.count == 1)
        #expect(creates[0].contains("ms-es-cmd-vite"))
    }

    @Test func testRunAutostartRespawnsADeadCommandWithItsCurrentConfig() async throws -> Void {
        let fake = FakeTmux(panes: [pane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (state, _) = try makeState(tmux: fake)
        await state.runAutostart()
        let calls = await fake.calls
        #expect(calls.contains([
            "respawn-pane", "-k", "-c", "/Users/test/Code/es", "-t", "ms-es-cmd-vite", "/bin/zsh", "-lc", "npm run dev",
        ]))
        #expect(!calls.contains { $0.first == "new-session" })
    }

    @Test func testUnknownSessionSetsActionError() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        await state.close(sessionName: "ms-es-term-zzzzzz")
        #expect(state.actionError != nil)
        #expect(await fake.calls.isEmpty)
    }

    @Test func testTmuxFailureSurfacesAsActionError() async throws {
        let fake = FakeTmux()
        await fake.failAll(with: TmuxError(message: "boom", exitCode: 1))
        let (state, _) = try makeState(tmux: fake)
        await state.start(commandSlug: "vite", projectSlug: "es")
        #expect(state.actionError == "boom")
    }

    @Test func testRestartAndRelaunchRespawnAndRefresh() async throws {
        let fake = FakeTmux(panes: [
            pane("ms-es-cmd-vite", kind: .command, name: "Vite"),
            pane("ms-es-agent-aaaaaa", kind: .agent, name: "Claude 1", template: "Claude"),
        ])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.restart(sessionName: "ms-es-cmd-vite")
        await state.relaunch(sessionName: "ms-es-agent-aaaaaa")
        let calls = await fake.calls
        #expect(calls.contains([
            "respawn-pane", "-k", "-c", "/Users/test/Code/es", "-t", "ms-es-cmd-vite", "/bin/zsh", "-lc", "npm run dev",
        ]))
        #expect(calls.contains(["respawn-pane", "-k", "-t", "ms-es-agent-aaaaaa"]))
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testStartAndRestartUseTheEditedRunAndPath() async throws -> Void {
        let fake = FakeTmux(panes: [pane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (state, url) = try makeState(tmux: fake)
        await state.refresh()
        try validYAML
            .replacingOccurrences(of: "npm run dev", with: "pnpm dev --port 5174")
            .replacingOccurrences(of: "~/Code/es", with: "~/Code/es-next")
            .write(to: url, atomically: true, encoding: .utf8)
        state.reloadConfig()
        await state.start(commandSlug: "vite", projectSlug: "es")
        await state.restart(sessionName: "ms-es-cmd-vite")
        let respawns = await fake.calls.filter { $0.first == "respawn-pane" }
        let expected = [
            "respawn-pane", "-k", "-c", "/Users/test/Code/es-next", "-t", "ms-es-cmd-vite",
            "/bin/zsh", "-lc", "pnpm dev --port 5174",
        ]
        #expect(respawns == [expected, expected])
    }

    @Test func testRestartOfOrphanCommandReusesItsOriginalCommand() async throws -> Void {
        let fake = FakeTmux(panes: [pane("ms-es-cmd-old", kind: .command, name: "Old")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.restart(sessionName: "ms-es-cmd-old")
        #expect(await fake.calls.contains(["respawn-pane", "-k", "-t", "ms-es-cmd-old"]))
    }

    @Test func testRestartAndRelaunchInMissingFolderRunNothing() async throws {
        let fake = FakeTmux(panes: [pane("ms-es-cmd-vite", kind: .command, name: "Vite")])
        let (state, _) = try makeState(tmux: fake, folderOK: false)
        await state.refresh()
        let before = await fake.calls.count
        await state.restart(sessionName: "ms-es-cmd-vite")
        #expect(state.actionError == "Folder not found: /Users/test/Code/es")
        state.actionError = nil
        await state.relaunch(sessionName: "ms-es-cmd-vite")
        #expect(state.actionError == "Folder not found: /Users/test/Code/es")
        #expect(await fake.calls.count == before)
    }

    @Test func testStartOnRunningCommandDoesNotRespawn() async throws {
        let fake = FakeTmux(panes: [pane("ms-es-cmd-vite", kind: .command, name: "Vite")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.start(commandSlug: "vite", projectSlug: "es")
        let calls = await fake.calls
        #expect(!calls.contains { $0.first == "respawn-pane" || $0.first == "new-session" })
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testConcurrentNewTerminalsGetDistinctNames() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        async let a = state.newTerminal(projectSlug: "es")
        async let b = state.newTerminal(projectSlug: "es")
        _ = await (a, b)
        let names = await fake.calls.filter { $0.first == "new-session" }.compactMap { args -> String? in
            guard let i = args.firstIndex(of: "@ms_name") else { return nil }
            return args[i + 1]
        }
        #expect(Set(names) == ["Terminal 1", "Terminal 2"])
    }

    @Test func testCloseKillsSessionAndRefreshes() async throws {
        let fake = FakeTmux(panes: [pane("ms-es-term-aaaaaa", kind: .terminal, name: "Terminal 1")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.close(sessionName: "ms-es-term-aaaaaa")
        let calls = await fake.calls
        #expect(calls.contains(["kill-session", "-t", "ms-es-term-aaaaaa"]))
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testRenameSetsNameAndRefreshes() async throws {
        let fake = FakeTmux(panes: [pane("ms-es-term-aaaaaa", kind: .terminal, name: "Terminal 1")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.rename(sessionName: "ms-es-term-aaaaaa", to: "Logs")
        let calls = await fake.calls
        #expect(calls.contains(["set-option", "-t", "ms-es-term-aaaaaa", "@ms_name", "Logs"]))
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testStopAllKillsServerAndRefreshes() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        let stopped = await state.stopAll()
        #expect(stopped)
        let calls = await fake.calls
        #expect(calls.first == ["kill-server"])
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testStopAllReturnsFalseAndSetsActionErrorWhenKillServerFails() async throws {
        let fake = FakeTmux()
        await fake.failAll(with: TmuxError(message: "boom", exitCode: 1))
        let (state, _) = try makeState(tmux: fake)
        let stopped = await state.stopAll()
        #expect(!stopped)
        #expect(state.actionError == "boom")
    }

    @Test func testNewTerminalAndAgentInMissingFolderRunNothing() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake, folderOK: false)
        #expect(await state.newTerminal(projectSlug: "es") == nil)
        #expect(state.actionError == "Folder not found: /Users/test/Code/es")
        state.actionError = nil
        #expect(await state.newAgent(projectSlug: "es", templateName: "Claude") == nil)
        #expect(state.actionError == "Folder not found: /Users/test/Code/es")
        #expect(await fake.calls.isEmpty)
    }

    @Test func testNewAgentWithUnknownTemplateSetsError() async throws {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        #expect(await state.newAgent(projectSlug: "es", templateName: "Nope") == nil)
        #expect(state.actionError != nil)
        #expect(await fake.calls.isEmpty)
    }
}
