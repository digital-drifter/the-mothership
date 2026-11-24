import Foundation
import Testing
@testable import MothershipCore

@Suite @MainActor struct AppStateTests {
    @Test func testLoadOfAnUnreadableFileShowsTheWarningAndNoProjects() throws -> Void {
        let (state, store) = try makeState(load: false, tmux: FakeTmux())
        try Data("not json".utf8).write(to: store.url)
        state.load()
        #expect(state.actionError?.contains("projects.json.unreadable-") == true)
        #expect(state.config == .empty)
        #expect(state.sections.isEmpty)
    }

    @Test func testStartNewCommandCallsNewSessionWithShellArgv() async throws -> Void {
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

    @Test func testStartDeadCommandRespawns() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.start(commandSlug: "vite", projectSlug: "es")
        let calls = await fake.calls
        #expect(calls.contains([
            "respawn-pane", "-k", "-c", "/Users/test/Code/es", "-t", "=ms-es-cmd-vite:", "/bin/zsh", "-lc", "npm run dev",
        ]))
        #expect(!calls.contains { $0.first == "new-session" })
    }

    @Test func testRefreshReportsRespawnedSessions() async throws -> Void {
        let fake = FakeTmux()
        await fake.script([
            [makePane("ms-es-cmd-vite", pid: 10, kind: .command, name: "Vite")],
            [makePane("ms-es-cmd-vite", pid: 11, kind: .command, name: "Vite")],
        ])
        let (state, _) = try makeState(tmux: fake)
        var reported: [Set<String>] = []
        state.onRespawn = { reported.append($0) }
        await state.refresh()
        await state.refresh()
        #expect(reported == [["ms-es-cmd-vite"]])
    }

    @Test func testStartInMissingFolderSetsErrorAndRunsNothing() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake, folderOK: false)
        await state.start(commandSlug: "vite", projectSlug: "es")
        #expect(state.actionError == "Folder not found: /Users/test/Code/es")
        #expect(await fake.calls.isEmpty)
    }

    @Test func testStopSignalsProcessGroupWhenPaneOutlivesGrace() async throws -> Void {
        let live = makePane("ms-es-cmd-vite", pid: 4242, kind: .command, name: "Vite")
        let fake = FakeTmux(panes: [live])
        let signals = Signals()
        let (state, _) = try makeState(tmux: fake, signals: signals)
        await state.refresh()
        await state.stop(sessionName: "ms-es-cmd-vite")
        #expect(signals.all == [4242])
        #expect(await fake.calls.contains(["send-keys", "-t", "=ms-es-cmd-vite:", "C-c"]))
    }

    @Test func testStopDoesNotSignalWhenPaneDiesInTime() async throws -> Void {
        let live = makePane("ms-es-cmd-vite", pid: 4242, kind: .command, name: "Vite")
        let dead = makePane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")
        let fake = FakeTmux()
        await fake.script([[live], [live], [dead]])
        let signals = Signals()
        let (state, _) = try makeState(tmux: fake, signals: signals)
        await state.refresh()
        await state.stop(sessionName: "ms-es-cmd-vite")
        #expect(signals.all.isEmpty)
    }

    @Test func testStopDoesNotSignalACommandRestartedDuringGrace() async throws -> Void {
        let live = makePane("ms-es-cmd-vite", pid: 4242, kind: .command, name: "Vite")
        let restarted = makePane("ms-es-cmd-vite", pid: 5555, kind: .command, name: "Vite")
        let fake = FakeTmux()
        await fake.script([[live], [live], [restarted]])
        let signals = Signals()
        let (state, _) = try makeState(tmux: fake, signals: signals)
        await state.refresh()
        await state.stop(sessionName: "ms-es-cmd-vite")
        #expect(signals.all.isEmpty)
    }

    @Test func testNewTerminalNumbersAfterHighestExisting() async throws -> Void {
        let fake = FakeTmux(panes: [
            makePane("ms-es-term-aaaaaa", kind: .terminal, name: "Terminal 1", created: 1),
            makePane("ms-es-term-bbbbbb", kind: .terminal, name: "Terminal 3", created: 2),
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

    @Test func testNewAgentUsesTheCatalogEntry() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        let session = try #require(await state.newAgent(projectSlug: "es", agentID: "claude"))
        #expect(session.hasPrefix("ms-es-agent-"))
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let s = try #require(create.firstIndex(of: "/bin/zsh"))
        #expect(Array(create[s...].prefix(3)) == ["/bin/zsh", "-lc", "claude"])
        let n = try #require(create.firstIndex(of: "@ms_name"))
        #expect(create[n + 1] == "Claude Code 1")
        let t = try #require(create.firstIndex(of: "@ms_template"))
        #expect(create[t + 1] == "Claude Code")
    }

    @Test func testRunAutostartStartsOnlyPlannedCommands() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        await state.runAutostart()
        let creates = await fake.calls.filter { $0.first == "new-session" }
        #expect(creates.count == 1)
        #expect(creates[0].contains("ms-es-cmd-vite"))
    }

    @Test func testRunAutostartRespawnsADeadCommandWithItsCurrentConfig() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (state, _) = try makeState(tmux: fake)
        await state.runAutostart()
        let calls = await fake.calls
        #expect(calls.contains([
            "respawn-pane", "-k", "-c", "/Users/test/Code/es", "-t", "=ms-es-cmd-vite:", "/bin/zsh", "-lc", "npm run dev",
        ]))
        #expect(!calls.contains { $0.first == "new-session" })
    }

    @Test func testUnknownSessionSetsActionError() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        await state.close(sessionName: "ms-es-term-zzzzzz")
        #expect(state.actionError != nil)
        #expect(await fake.calls.isEmpty)
    }

    @Test func testTmuxFailureSurfacesAsActionError() async throws -> Void {
        let fake = FakeTmux()
        await fake.failAll(with: TmuxError(message: "boom", exitCode: 1))
        let (state, _) = try makeState(tmux: fake)
        await state.start(commandSlug: "vite", projectSlug: "es")
        #expect(state.actionError == "boom")
    }

    @Test func testRestartAndRelaunchRespawnAndRefresh() async throws -> Void {
        let fake = FakeTmux(panes: [
            makePane("ms-es-cmd-vite", kind: .command, name: "Vite"),
            makePane("ms-es-agent-aaaaaa", kind: .agent, name: "Claude 1", template: "Claude"),
        ])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.restart(sessionName: "ms-es-cmd-vite")
        await state.relaunch(sessionName: "ms-es-agent-aaaaaa")
        let calls = await fake.calls
        #expect(calls.contains([
            "respawn-pane", "-k", "-c", "/Users/test/Code/es", "-t", "=ms-es-cmd-vite:", "/bin/zsh", "-lc", "npm run dev",
        ]))
        #expect(calls.contains(["respawn-pane", "-k", "-t", "=ms-es-agent-aaaaaa:"]))
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testStartAndRestartUseTheEditedRunAndPath() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (state, store) = try makeState(tmux: fake)
        await state.refresh()
        var edited = validConfig
        edited.projects[0].path = "/Users/test/Code/es-next"
        edited.projects[0].commands[0].run = "pnpm dev --port 5174"
        try store.save(edited)
        state.load()
        await state.start(commandSlug: "vite", projectSlug: "es")
        await state.restart(sessionName: "ms-es-cmd-vite")
        let respawns = await fake.calls.filter { $0.first == "respawn-pane" }
        let expected = [
            "respawn-pane", "-k", "-c", "/Users/test/Code/es-next", "-t", "=ms-es-cmd-vite:",
            "/bin/zsh", "-lc", "pnpm dev --port 5174",
        ]
        #expect(respawns == [expected, expected])
    }

    @Test func testRestartOfOrphanCommandReusesItsOriginalCommand() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-old", kind: .command, name: "Old")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.restart(sessionName: "ms-es-cmd-old")
        #expect(await fake.calls.contains(["respawn-pane", "-k", "-t", "=ms-es-cmd-old:"]))
    }

    @Test func testRestartAndRelaunchInMissingFolderRunNothing() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-vite", kind: .command, name: "Vite")])
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

    @Test func testStartOnRunningCommandDoesNotRespawn() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-vite", kind: .command, name: "Vite")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.start(commandSlug: "vite", projectSlug: "es")
        let calls = await fake.calls
        #expect(!calls.contains { $0.first == "respawn-pane" || $0.first == "new-session" })
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testConcurrentNewTerminalsGetDistinctNames() async throws -> Void {
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

    @Test func testCloseKillsSessionAndRefreshes() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-term-aaaaaa", kind: .terminal, name: "Terminal 1")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.close(sessionName: "ms-es-term-aaaaaa")
        let calls = await fake.calls
        #expect(calls.contains(["kill-session", "-t", "=ms-es-term-aaaaaa:"]))
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testRenameSetsNameAndRefreshes() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-term-aaaaaa", kind: .terminal, name: "Terminal 1")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.rename(sessionName: "ms-es-term-aaaaaa", to: "Logs")
        let calls = await fake.calls
        #expect(calls.contains(["set-option", "-t", "=ms-es-term-aaaaaa:", "@ms_name", "Logs"]))
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testRenameReplacesControlCharactersWithSpaces() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-term-aaaaaa", kind: .terminal, name: "Terminal 1")])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.rename(sessionName: "ms-es-term-aaaaaa", to: "Lo\tgs\r\nnow")
        #expect(await fake.calls.contains(["set-option", "-t", "=ms-es-term-aaaaaa:", "@ms_name", "Lo gs  now"]))
    }

    @Test func testRefreshKillsOnlyDeadCommandsMissingFromConfig() async throws -> Void {
        var otherProject = makePane("ms-gone-cmd-web", dead: true, kind: .command, name: "Web")
        otherProject.project = "gone"
        let fake = FakeTmux(panes: [
            makePane("ms-es-cmd-old", dead: true, kind: .command, name: "Old"),
            otherProject,
            makePane("ms-es-cmd-live", kind: .command, name: "Live"),
            makePane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite"),
            makePane("ms-es-agent-aaaaaa", dead: true, kind: .agent, name: "Claude 1", template: "Claude"),
        ])
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        let kills = await fake.calls.filter { $0.first == "kill-session" }
        #expect(kills == [["kill-session", "-t", "=ms-es-cmd-old:"], ["kill-session", "-t", "=ms-gone-cmd-web:"]])
        let commands = state.sections.flatMap(\.commands).map(\.id)
        #expect(!commands.contains("ms-es-cmd-old"))
        #expect(state.actionError == nil)
    }

    @Test func testRefreshKillsNothingBeforeAConfigHasLoaded() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (state, _) = try makeState(load: false, tmux: fake)
        await state.refresh()
        #expect(!(await fake.calls.contains { $0.first == "kill-session" }))
    }

    @Test func testAnOlderPaneListNeverReplacesANewerOne() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        // The 1 s loop's list-panes starts before a terminal is created but finishes after create's refresh.
        await fake.holdNextListPanes()
        let loop = Task { await state.refresh() }
        while await fake.heldCount == 0 { await Task.yield() }
        await fake.script([[makePane("ms-es-term-aaaaaa", kind: .terminal, name: "Terminal 1")]])
        await state.refresh()
        await fake.releaseHeld()
        await loop.value
        #expect(state.sections.first?.terminals.map(\.id) == ["ms-es-term-aaaaaa"])
    }

    @Test func testStopAllKillsServerAndRefreshes() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        let stopped = await state.stopAll()
        #expect(stopped)
        let calls = await fake.calls
        #expect(calls.first == ["kill-server"])
        #expect(calls.last?.first == "list-panes")
    }

    @Test func testStopAllReturnsFalseAndSetsActionErrorWhenKillServerFails() async throws -> Void {
        let fake = FakeTmux()
        await fake.failAll(with: TmuxError(message: "boom", exitCode: 1))
        let (state, _) = try makeState(tmux: fake)
        let stopped = await state.stopAll()
        #expect(!stopped)
        #expect(state.actionError == "boom")
    }

    @Test func testNewTerminalAndAgentInMissingFolderRunNothing() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake, folderOK: false)
        #expect(await state.newTerminal(projectSlug: "es") == nil)
        #expect(state.actionError == "Folder not found: /Users/test/Code/es")
        state.actionError = nil
        #expect(await state.newAgent(projectSlug: "es", agentID: "claude") == nil)
        #expect(state.actionError == "Folder not found: /Users/test/Code/es")
        #expect(await fake.calls.isEmpty)
    }

    @Test func testNewAgentWithADisabledOrUnknownIdSetsError() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        for id in ["codex", "nope"] {
            state.actionError = nil
            #expect(await state.newAgent(projectSlug: "es", agentID: id) == nil)
            #expect(state.actionError == "Unknown agent: \(id)")
        }
        #expect(await !fake.calls.contains { $0.first == "new-session" })
    }
}
