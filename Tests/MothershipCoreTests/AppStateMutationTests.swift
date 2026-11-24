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

    private var frontendConfig: MothershipConfig {
        var config = validConfig
        config.projects[0].commands[0].directory = "frontend"
        return config
    }

    private func missingFrontend(_ path: String) -> Bool { path != "/Users/test/Code/es/frontend" }

    @Test func testStartUsesTheCommandDirectory() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(config: frontendConfig, tmux: fake)
        await state.start(commandSlug: "vite", projectSlug: "es")
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let c = try #require(create.firstIndex(of: "-c"))
        #expect(create[c + 1] == "/Users/test/Code/es/frontend")

        let dead = FakeTmux(panes: [makePane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (second, _) = try makeState(config: frontendConfig, tmux: dead)
        await second.refresh()
        await second.restart(sessionName: "ms-es-cmd-vite")
        #expect(await dead.calls.contains {
            $0.first == "respawn-pane" && $0.starts(with: ["respawn-pane", "-k", "-c", "/Users/test/Code/es/frontend"])
        })
    }

    @Test func testChangeFolderCarriesRelativeDirectories() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(config: frontendConfig, tmux: fake)
        state.changeFolder(projectSlug: "es", to: "/new/es")
        await state.start(commandSlug: "vite", projectSlug: "es")
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let c = try #require(create.firstIndex(of: "-c"))
        #expect(create[c + 1] == "/new/es/frontend")
    }

    @Test func testStartInAMissingCommandDirectoryRunsNothing() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(config: frontendConfig, tmux: fake, directoryExists: missingFrontend)
        await state.start(commandSlug: "vite", projectSlug: "es")
        #expect(state.actionError == "Folder not found: /Users/test/Code/es/frontend")
        #expect(!(await fake.calls.contains { $0.first == "new-session" }))

        let dead = FakeTmux(panes: [makePane("ms-es-cmd-vite", dead: true, kind: .command, name: "Vite")])
        let (second, _) = try makeState(config: frontendConfig, tmux: dead, directoryExists: missingFrontend)
        await second.refresh()
        await second.restart(sessionName: "ms-es-cmd-vite")
        #expect(second.actionError == "Folder not found: /Users/test/Code/es/frontend")
        #expect(!(await dead.calls.contains { $0.first == "respawn-pane" }))
    }

    @Test func testValidateCommandRejectsAMissingDirectory() throws -> Void {
        let (state, _) = try makeState(tmux: FakeTmux(), directoryExists: missingFrontend)
        #expect(state.validateCommand(projectSlug: "es", name: "Web", run: "x", directory: "frontend", editing: nil)
            == "Folder not found: /Users/test/Code/es/frontend")
        #expect(state.validateCommand(projectSlug: "es", name: "Web", run: "x", directory: "  ", editing: nil) == nil)
    }

    @Test func testAddAndEditCommandStoreTheDirectory() async throws -> Void {
        let (state, store) = try makeState(tmux: FakeTmux())
        let session = try #require(await state.addCommand(
            projectSlug: "es", name: "Api", run: "serve", directory: " api ", autostart: false))
        #expect(session == "ms-es-cmd-api")
        #expect(project("es", in: store)?.commands.first { $0.slug == "api" }?.directory == "api")
        await state.editCommand(
            projectSlug: "es", commandSlug: "api", name: "Api", run: "serve", directory: "", autostart: false)
        #expect(project("es", in: store)?.commands.first { $0.slug == "api" }?.directory == nil)
    }

    @Test func testAddAndEditCommandStoreAbsolutePathsInsideTheProjectAsRelative() async throws -> Void {
        let (state, store) = try makeState(tmux: FakeTmux())
        await state.addCommand(projectSlug: "es", name: "Api", run: "serve", directory: "/Users/test/Code/es/frontend", autostart: false)
        #expect(project("es", in: store)?.commands.first { $0.slug == "api" }?.directory == "frontend")
        await state.editCommand(
            projectSlug: "es", commandSlug: "api", name: "Api", run: "serve", directory: "/Users/test/Code/es", autostart: false)
        #expect(project("es", in: store)?.commands.first { $0.slug == "api" }?.directory == nil)
        await state.editCommand(
            projectSlug: "es", commandSlug: "api", name: "Api", run: "serve", directory: "/opt/other", autostart: false)
        #expect(project("es", in: store)?.commands.first { $0.slug == "api" }?.directory == "/opt/other")
    }

    @Test func testTildeDirectoriesStayUnexpandedOutsideTheProjectAndGoRelativeInside() async throws -> Void {
        let (state, store) = try makeState(tmux: FakeTmux())
        await state.addCommand(projectSlug: "es", name: "Api", run: "serve", directory: "~/elsewhere", autostart: false)
        #expect(project("es", in: store)?.commands.first { $0.slug == "api" }?.directory == "~/elsewhere")
        state.changeFolder(projectSlug: "es", to: NSHomeDirectory() + "/proj")
        await state.editCommand(
            projectSlug: "es", commandSlug: "api", name: "Api", run: "serve", directory: "~/proj/web", autostart: false)
        #expect(project("es", in: store)?.commands.first { $0.slug == "api" }?.directory == "web")
    }

    @Test func testStartPassesAnAbsoluteDirectoryAsTheExactWorkingDirectory() async throws -> Void {
        var config = validConfig
        config.projects[0].commands[0].directory = "/opt/other"
        let fake = FakeTmux()
        let (state, _) = try makeState(config: config, tmux: fake)
        await state.start(commandSlug: "vite", projectSlug: "es")
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let c = try #require(create.firstIndex(of: "-c"))
        #expect(create[c + 1] == "/opt/other")
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
        await state.addCommand(projectSlug: "es", name: "Horizon", run: "php artisan horizon", directory: "", autostart: true)
        expectUnchanged("addCommand")
        await state.deleteCommand(projectSlug: "es", commandSlug: "vite")
        expectUnchanged("deleteCommand")
        await state.removeProject(slug: "es")
        expectUnchanged("removeProject")
        #expect(await fake.calls.allSatisfy { $0.first == "list-panes" })
    }

    @Test func testEnabledAgentsFollowCatalogOrderAndSkipUnknownIds() throws -> Void {
        var config = validConfig
        config.enabledAgents = ["amp", "gone", "claude"]
        let (state, _) = try makeState(config: config, tmux: FakeTmux())
        #expect(state.enabledAgents.map(\.id) == ["claude", "amp"])
    }

    @Test func testSetAgentSavesAndNeverTouchesTmux() async throws -> Void {
        let fake = FakeTmux()
        await fake.script([[makePane("ms-es-agent-aaa", kind: .agent, name: "Claude Code 1", template: "Claude Code")]])
        let (state, store) = try makeState(tmux: fake)
        await state.refresh()
        state.setAgent("codex", enabled: true)
        #expect(reloaded(store).enabledAgents.contains("codex"))
        #expect(state.isAgentEnabled("codex"))
        state.setAgent("claude", enabled: false)
        #expect(!reloaded(store).enabledAgents.contains("claude"))
        #expect(!state.isAgentEnabled("claude"))
        #expect(await fake.calls.allSatisfy { $0.first == "list-panes" })
    }

    @Test func testSetAgentRefusesWhenTheFileCannotBeSaved() throws -> Void {
        let (state, store) = try makeState(tmux: FakeTmux())
        let folder = store.url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        let before = state.enabledAgents
        state.setAgent("codex", enabled: true)
        #expect(state.enabledAgents == before)
        #expect(state.actionError?.hasPrefix("Couldn't save projects.json: ") == true)
    }

    @Test func testSetAgentRejectsAnUnknownId() throws -> Void {
        let (state, store) = try makeState(tmux: FakeTmux())
        state.setAgent("nope", enabled: true)
        #expect(state.actionError == "Unknown agent: nope")
        #expect(reloaded(store).enabledAgents == ["claude"])
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
        state.setAgent("codex", enabled: true)
        expectRefused("setAgent")
        await state.removeProject(slug: "es")
        expectRefused("removeProject")
        #expect(try Data(contentsOf: store.url) == original)
        #expect(await fake.calls.allSatisfy { $0.first == "list-panes" })
    }

    @Test func testValidateCommandRejectsBlankAndDuplicateNames() throws -> Void {
        let (state, _) = try makeState(tmux: FakeTmux())
        #expect(state.validateCommand(projectSlug: "es", name: "", run: "x", directory: "", editing: nil) == "Name can't be empty.")
        #expect(state.validateCommand(projectSlug: "es", name: "  ", run: "x", directory: "", editing: nil) == "Name can't be empty.")
        #expect(state.validateCommand(projectSlug: "es", name: "vite", run: "x", directory: "", editing: nil)
            == "A command named “vite” already exists in this project.")
        #expect(state.validateCommand(projectSlug: "es", name: "Horizon", run: " ", directory: "", editing: nil) == "Command can't be empty.")
        #expect(state.validateCommand(projectSlug: "es", name: "Vite", run: "x", directory: "", editing: "vite") == nil)
        #expect(state.validateCommand(projectSlug: "es", name: "Horizon", run: "x", directory: "", editing: nil) == nil)
    }

    @Test func testAddCommandSavesAndStartsIt() async throws -> Void {
        let fake = FakeTmux()
        let (state, store) = try makeState(tmux: fake)
        let session = await state.addCommand(projectSlug: "es", name: "Horizon", run: "php artisan horizon", directory: "", autostart: true)
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
        let session = await state.addCommand(projectSlug: "es", name: "Vite!", run: "npm run dev", directory: "", autostart: false)
        #expect(session == "ms-es-cmd-vite-2")
        #expect(project("es", in: store)?.commands.contains { $0.slug == "vite-2" } == true)
    }

    @Test func testEditCommandRenamesTheRunningSessionAndKeepsItsSlug() async throws -> Void {
        let fake = FakeTmux(panes: [makePane("ms-es-cmd-vite", kind: .command, name: "Vite")])
        let (state, store) = try makeState(tmux: fake)
        await state.refresh()
        await state.editCommand(
            projectSlug: "es", commandSlug: "vite", name: "Vite Dev", run: "npm run dev -- --host", directory: "", autostart: false)
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
        await state.editCommand(projectSlug: "es", commandSlug: "vite", name: "Vite Dev", run: "x", directory: "", autostart: true)
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

    @Test func testNewCustomAgentStartsWithoutTouchingTheList() async throws -> Void {
        let fake = FakeTmux()
        let (state, _) = try makeState(tmux: fake)
        let before = state.config.enabledAgents
        let session = try #require(await state.newCustomAgent(projectSlug: "es", name: "Claude Resume", run: "claude --resume"))
        #expect(session.hasPrefix("ms-es-agent-"))
        let create = try #require(await fake.calls.first { $0.first == "new-session" })
        let s = try #require(create.firstIndex(of: "/bin/zsh"))
        #expect(Array(create[s...].prefix(3)) == ["/bin/zsh", "-lc", "claude --resume"])
        let n = try #require(create.firstIndex(of: "@ms_name"))
        #expect(create[n + 1] == "Claude Resume 1")
        let t = try #require(create.firstIndex(of: "@ms_template"))
        #expect(create[t + 1] == "Claude Resume")
        #expect(state.config.enabledAgents == before)
    }
}
