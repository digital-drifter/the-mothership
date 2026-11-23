import Foundation
import Testing
@testable import MothershipCore

@Suite @MainActor struct AppStateMutationTests {
    private func reloaded(_ store: ProjectStore) -> MothershipConfig { store.load().config }

    private func project(_ slug: String, in store: ProjectStore) -> ProjectConfig? {
        reloaded(store).projects.first { $0.slug == slug }
    }

    @Test func testAddProjectNamesItAfterTheFolderAndSaves() throws -> Void {
        let (state, store) = try makeState(config: .empty, tmux: FakeTmux())
        let slug = state.addProject(path: "/Users/test/Code/acme")
        #expect(slug == "acme")
        let saved = try #require(project("acme", in: store))
        #expect(saved.name == "acme")
        #expect(saved.path == "/Users/test/Code/acme")
        #expect(saved.commands.isEmpty)
        #expect(state.sections.contains { $0.id == "acme" })
    }

    @Test func testAddProjectTwiceSelectsTheExistingOne() throws -> Void {
        let (state, store) = try makeState(config: .empty, tmux: FakeTmux())
        let first = state.addProject(path: "/x/app")
        #expect(state.addProject(path: "/x/app/") == first)
        #expect(state.addProject(path: "/x/y/../app") == first)
        #expect(first == "app")
        #expect(reloaded(store).projects.count == 1)
    }

    @Test func testFoldersWithTheSameNameGetDistinctSlugs() throws -> Void {
        let (state, _) = try makeState(config: .empty, tmux: FakeTmux())
        #expect(state.addProject(path: "/a/app") == "app")
        #expect(state.addProject(path: "/b/app") == "app-2")
    }

    @Test func testRenameProjectKeepsItsSlug() throws -> Void {
        let (state, store) = try makeState(tmux: FakeTmux())
        state.renameProject(slug: "es", to: "Event Sprout")
        let saved = try #require(project("es", in: store))
        #expect(saved.name == "Event Sprout")
    }

    @Test func testChangeFolderUpdatesThePathUsedByTheNextStart() async throws -> Void {
        let fake = FakeTmux()
        let (state, store) = try makeState(tmux: fake)
        state.changeFolder(projectSlug: "es", to: "/new/es")
        #expect(project("es", in: store)?.path == "/new/es")
        await state.start(commandSlug: "vite", projectSlug: "es")
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let c = try #require(create.firstIndex(of: "-c"))
        #expect(create[c + 1] == "/new/es")
    }

    @Test func testRemoveProjectSavesThenKillsEveryOneOfItsSessions() async throws -> Void {
        let fake = FakeTmux(panes: [
            makePane("ms-es-agent-aaaaaa", kind: .agent, name: "Claude 1", template: "Claude"),
            makePane("ms-es-term-bbbbbb", kind: .terminal, name: "Terminal 1"),
            makePane("ms-es-cmd-vite", kind: .command, name: "Vite"),
            makePane("ms-other-term-cccccc", kind: .terminal, name: "Terminal 1", project: "other"),
        ])
        let (state, store) = try makeState(tmux: fake)
        #expect(state.runningSessionCount(projectSlug: "es") == 0)
        await state.refresh()
        #expect(state.runningSessionCount(projectSlug: "es") == 3)
        await state.removeProject(slug: "es")
        #expect(project("es", in: store) == nil)
        let kills = await fake.calls.filter { $0.first == "kill-session" }
        #expect(Set(kills) == [
            ["kill-session", "-t", "=ms-es-agent-aaaaaa:"],
            ["kill-session", "-t", "=ms-es-term-bbbbbb:"],
            ["kill-session", "-t", "=ms-es-cmd-vite:"],
        ])
        #expect(kills.count == 3)
    }

    @Test func testRemoveProjectTreatsAMissingSessionAsKilledAndKeepsGoing() async throws -> Void {
        let fake = FakeTmux(panes: [
            makePane("ms-es-cmd-vite", kind: .command, name: "Vite"),
            makePane("ms-es-agent-aaaaaa", kind: .agent, name: "Claude 1", template: "Claude"),
            makePane("ms-es-term-bbbbbb", kind: .terminal, name: "Terminal 1"),
        ])
        await fake.fail(["kill-session", "-t", "=ms-es-cmd-vite:"], with: TmuxError(message: "can't find session: ms-es-cmd-vite", exitCode: 1))
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.removeProject(slug: "es")
        let kills = await fake.calls.filter { $0.first == "kill-session" }
        #expect(kills.count == 3)
        #expect(state.actionError == nil)
    }

    @Test func testRemoveProjectKeepsKillingAfterARealErrorAndReportsTheFirst() async throws -> Void {
        let fake = FakeTmux(panes: [
            makePane("ms-es-cmd-vite", kind: .command, name: "Vite"),
            makePane("ms-es-agent-aaaaaa", kind: .agent, name: "Claude 1", template: "Claude"),
            makePane("ms-es-term-bbbbbb", kind: .terminal, name: "Terminal 1"),
        ])
        await fake.fail(["kill-session", "-t", "=ms-es-cmd-vite:"], with: TmuxError(message: "permission denied", exitCode: 1))
        await fake.fail(["kill-session", "-t", "=ms-es-term-bbbbbb:"], with: TmuxError(message: "second failure", exitCode: 1))
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.removeProject(slug: "es")
        let kills = await fake.calls.filter { $0.first == "kill-session" }
        #expect(kills.count == 3)
        #expect(state.actionError == "permission denied")
    }

    @Test func testDeleteCommandIgnoresAMissingSessionButReportsOtherErrors() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-queue", kind: .command, name: "Queue")])
        await fake.fail(["kill-session", "-t", "=ms-es-cmd-queue:"], with: TmuxError(message: "can't find session: ms-es-cmd-queue", exitCode: 1))
        let (state, _) = try makeState(tmux: fake)
        await state.refresh()
        await state.deleteCommand(projectSlug: "es", commandSlug: "queue")
        #expect(state.actionError == nil)
        await fake.fail(["kill-session", "-t", "=ms-es-cmd-queue:"], with: TmuxError(message: "boom", exitCode: 1))
        await state.deleteCommand(projectSlug: "es", commandSlug: "queue")
        #expect(state.actionError == "boom")
    }

    @Test func testAFailedSaveChangesNothing() async throws -> Void {
        let fake = FakeTmux()
        let (state, store) = try makeState(tmux: fake)
        // Make the store's folder a regular file so writing projects.json fails.
        let folder = store.url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        let before = state.config

        func expectUnchanged(_ label: String) -> Void {
            #expect(state.config == before, "\(label) changed the config")
            #expect(state.actionError?.hasPrefix("Couldn't save projects.json: ") == true, "\(label) set no error")
            state.actionError = nil
        }

        state.addProject(path: "/x/new")
        expectUnchanged("addProject")
        state.renameProject(slug: "es", to: "Other")
        expectUnchanged("renameProject")
        await state.addCommand(projectSlug: "es", name: "Horizon", run: "php artisan horizon", autostart: true)
        expectUnchanged("addCommand")
        await state.deleteCommand(projectSlug: "es", commandSlug: "vite")
        expectUnchanged("deleteCommand")
        await state.removeProject(slug: "es")
        expectUnchanged("removeProject")
        #expect(await fake.calls.allSatisfy { $0.first == "list-panes" })
    }

    @Test func testEditsAreRefusedWhileProjectsJsonCannotBeSaved() async throws -> Void {
        let fake = FakeTmux()
        let (state, store) = try makeState(config: .empty, load: false, tmux: fake)
        let original = Data("not json".utf8)
        try original.write(to: store.url)
        // A read-only folder lets the file be read but not moved aside, so loading leaves saving off.
        let folder = store.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        state.load()
        let loadedConfig = state.config
        #expect(loadedConfig == .empty)

        func expectRefused(_ label: String) -> Void {
            #expect(state.config == loadedConfig, "\(label) changed the config")
            #expect(state.actionError == "Changes can't be saved until the unreadable projects.json is fixed or removed.",
                    "\(label) gave the wrong error")
            state.actionError = nil
        }

        state.actionError = nil
        state.addProject(path: "/x/new")
        expectRefused("addProject")
        state.addAgentTemplate(name: "Aider", run: "aider")
        expectRefused("addAgentTemplate")
        state.removeAgentTemplate(name: "Claude")
        expectRefused("removeAgentTemplate")
        await state.removeProject(slug: "es")
        expectRefused("removeProject")
        #expect(try Data(contentsOf: store.url) == original)
        #expect(await fake.calls.allSatisfy { $0.first == "list-panes" })
    }

    @Test func testValidateCommandRejectsBlankAndDuplicateNames() throws -> Void {
        let (state, _) = try makeState(tmux: FakeTmux())
        #expect(state.validateCommand(projectSlug: "es", name: "", run: "x", editing: nil) == "Name can't be empty.")
        #expect(state.validateCommand(projectSlug: "es", name: "  ", run: "x", editing: nil) == "Name can't be empty.")
        #expect(state.validateCommand(projectSlug: "es", name: "vite", run: "x", editing: nil)
            == "A command named “vite” already exists in this project.")
        #expect(state.validateCommand(projectSlug: "es", name: "Horizon", run: " ", editing: nil) == "Command can't be empty.")
        #expect(state.validateCommand(projectSlug: "es", name: "Vite", run: "x", editing: "vite") == nil)
        #expect(state.validateCommand(projectSlug: "es", name: "Horizon", run: "x", editing: nil) == nil)
    }

    @Test func testAddCommandSavesAndStartsIt() async throws -> Void {
        let fake = FakeTmux()
        let (state, store) = try makeState(tmux: fake)
        let session = await state.addCommand(projectSlug: "es", name: "Horizon", run: "php artisan horizon", autostart: true)
        #expect(session == "ms-es-cmd-horizon")
        let saved = try #require(project("es", in: store)?.commands.first { $0.slug == "horizon" })
        #expect(saved.autostart)
        #expect(saved.run == "php artisan horizon")
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let s = try #require(create.firstIndex(of: "/bin/zsh"))
        #expect(Array(create[s...].prefix(3)) == ["/bin/zsh", "-lc", "php artisan horizon"])
    }

    @Test func testAddCommandWithADuplicateSlugGetsANumber() async throws -> Void {
        let (state, store) = try makeState(tmux: FakeTmux())
        let session = await state.addCommand(projectSlug: "es", name: "Vite!", run: "npm run dev", autostart: false)
        #expect(session == "ms-es-cmd-vite-2")
        #expect(project("es", in: store)?.commands.contains { $0.slug == "vite-2" } == true)
    }

    @Test func testEditCommandRenamesTheRunningSessionAndKeepsItsSlug() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-vite", kind: .command, name: "Vite")])
        let (state, store) = try makeState(tmux: fake)
        await state.refresh()
        await state.editCommand(
            projectSlug: "es", commandSlug: "vite", name: "Vite Dev", run: "npm run dev -- --host", autostart: false)
        let saved = try #require(project("es", in: store)?.commands.first { $0.slug == "vite" })
        #expect(saved.name == "Vite Dev")
        #expect(saved.run == "npm run dev -- --host")
        let calls = await fake.calls
        #expect(calls.contains(["set-option", "-t", "=ms-es-cmd-vite:", "@ms_name", "Vite Dev"]))
        #expect(!calls.contains { $0.first == "respawn-pane" || $0.first == "kill-session" })
        await state.refresh()
        let names = state.sections.flatMap(\.commands).map(\.displayName)
        #expect(names.contains("Vite Dev"))
        #expect(!names.contains("Vite"))
    }

    @Test func testEditCommandOfAStoppedCommandMakesNoTmuxChange() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        await state.editCommand(projectSlug: "es", commandSlug: "vite", name: "Vite Dev", run: "x", autostart: true)
        #expect(await fake.calls.allSatisfy { $0.first == "list-panes" })
    }

    @Test func testDeleteCommandKillsItsSessionAndForgetsIt() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-queue", kind: .command, name: "Queue")])
        let (state, store) = try makeState(tmux: fake)
        await state.refresh()
        await state.deleteCommand(projectSlug: "es", commandSlug: "queue")
        #expect(project("es", in: store)?.commands.map(\.slug) == ["vite"])
        #expect(await fake.calls.contains(["kill-session", "-t", "=ms-es-cmd-queue:"]))
    }

    @Test func testDeletingANeverStartedCommandMakesNoKillCall() async throws -> Void {
        let fake = FakeTmux()
        let (state, store) = try makeState(tmux: fake)
        await state.deleteCommand(projectSlug: "es", commandSlug: "queue")
        #expect(project("es", in: store)?.commands.map(\.slug) == ["vite"])
        #expect(await !fake.calls.contains { $0.first == "kill-session" })
    }

    @Test func testAgentTemplatesAddRemoveAndRejectDuplicates() throws -> Void {
        let (state, store) = try makeState(tmux: FakeTmux())
        #expect(state.validateAgentTemplate(name: "claude", run: "x") == "An agent named “claude” is already in the list.")
        #expect(state.validateAgentTemplate(name: " ", run: "x") == "Name can't be empty.")
        #expect(state.validateAgentTemplate(name: "Aider", run: " ") == "Command can't be empty.")
        #expect(state.validateAgentTemplate(name: "Aider", run: "aider") == nil)
        state.addAgentTemplate(name: "Aider", run: "aider")
        #expect(reloaded(store).agents == [AgentTemplate(name: "Claude", run: "claude"), AgentTemplate(name: "Aider", run: "aider")])
        state.removeAgentTemplate(name: "Claude")
        #expect(reloaded(store).agents == [AgentTemplate(name: "Aider", run: "aider")])
        state.removeAgentTemplate(name: "Aider")
        #expect(reloaded(store).agents == [])
        #expect(state.agents == [])
    }

    @Test func testNewCustomAgentStartsWithoutTouchingTheList() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        let before = state.config.agents
        let session = try #require(await state.newCustomAgent(projectSlug: "es", name: "Claude Resume", run: "claude --resume"))
        #expect(session.hasPrefix("ms-es-agent-"))
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let s = try #require(create.firstIndex(of: "/bin/zsh"))
        #expect(Array(create[s...].prefix(3)) == ["/bin/zsh", "-lc", "claude --resume"])
        let n = try #require(create.firstIndex(of: "@ms_name"))
        #expect(create[n + 1] == "Claude Resume 1")
        let t = try #require(create.firstIndex(of: "@ms_template"))
        #expect(create[t + 1] == "Claude Resume")
        #expect(state.config.agents == before)
    }
}
