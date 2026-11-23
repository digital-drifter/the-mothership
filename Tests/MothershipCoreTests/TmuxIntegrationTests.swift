import Foundation
import Testing
@testable import MothershipCore

private let tmuxAvailable: Bool =
    TmuxLocator.find(environmentPath: ProcessInfo.processInfo.environment["PATH"]) != nil

/// A throwaway tmux server on its own socket, killed by `cleanup()`.
private struct Fixture {
    let client: TmuxClient
    let socket: String
    let tmuxPath: String
    let directory: URL

    init() throws {
        tmuxPath = TmuxLocator.find(environmentPath: ProcessInfo.processInfo.environment["PATH"])!
        socket = "ms-test-\(UUID().uuidString.prefix(8))"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = try TmuxConfig.install(in: directory)
        client = TmuxClient(tmuxPath: tmuxPath, configPath: config.path, socketName: socket)
    }

    func cleanup() -> Void {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-L", socket, "kill-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    func metadata(kind: ItemKind = .command) -> SessionMetadata {
        SessionMetadata(project: "proj", kind: kind, name: "Web", template: "tpl")
    }

    func waitForPane(_ session: String, until predicate: (PaneInfo) -> Bool) async throws -> PaneInfo? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let pane = try await client.listPanes().first(where: { $0.sessionName == session }), predicate(pane) {
                return pane
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

@Suite(.enabled(if: tmuxAvailable))
struct TmuxIntegrationTests {
    @Test func testListPanesWithNoServerReturnsEmpty() async throws -> Void {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let panes = try await fixture.client.listPanes()
        #expect(panes.isEmpty)
    }

    @Test func testNewSessionStoresMetadata() async throws -> Void {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.client.newSession(
            name: "ms-proj-cmd-web", directory: "/tmp",
            command: ["/bin/sh", "-c", "sleep 30"], metadata: fixture.metadata())
        let pane = try await fixture.waitForPane("ms-proj-cmd-web") { _ in true }
        #expect(pane?.project == "proj")
        #expect(pane?.kind == .command)
        #expect(pane?.name == "Web")
        #expect(pane?.template == "tpl")
        #expect(pane?.isDead == false)
        #expect(pane?.deadStatus == nil)
    }

    @Test func testCommandWithQuotesPipesAndAndsRunsVerbatim() async throws -> Void {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tmpFile = fixture.directory.appendingPathComponent("out.txt").path
        try await fixture.client.newSession(
            name: "ms-proj-cmd-quote", directory: "/tmp",
            command: ["/bin/sh", "-lc", "printf '%s\\n' \"a b\" | tr a-z A-Z && echo \"ok\" > \(tmpFile); sleep 30"],
            metadata: fixture.metadata())
        let deadline = Date().addingTimeInterval(3)
        var contents = ""
        while Date() < deadline {
            contents = (try? String(contentsOfFile: tmpFile, encoding: .utf8)) ?? ""
            if contents.contains("ok") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(contents.contains("ok"))
        let captured = try await fixture.client.run(["capture-pane", "-p", "-t", "ms-proj-cmd-quote"])
        #expect(captured.contains("A B"))
    }

    @Test func testDeadPaneRemainsWithExitStatus() async throws -> Void {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.client.newSession(
            name: "ms-proj-cmd-dead", directory: "/tmp",
            command: ["/bin/sh", "-c", "exit 3"], metadata: fixture.metadata())
        let pane = try await fixture.waitForPane("ms-proj-cmd-dead") { $0.isDead }
        #expect(pane?.isDead == true)
        #expect(pane?.deadStatus == 3)
    }

    @Test func testRespawnRestartsDeadPane() async throws -> Void {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let log = fixture.directory.appendingPathComponent("runs.txt").path
        try await fixture.client.newSession(
            name: "ms-proj-cmd-re", directory: "/tmp",
            command: ["/bin/sh", "-c", "echo run >> \(log); exit 3"], metadata: fixture.metadata())
        _ = try await fixture.waitForPane("ms-proj-cmd-re") { $0.isDead }
        try await fixture.client.respawn(session: "ms-proj-cmd-re")
        // The command appends a line per run, so two lines prove the dead pane was restarted.
        let deadline = Date().addingTimeInterval(3)
        var runs = 0
        while Date() < deadline, runs < 2 {
            let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            runs = text.split(separator: "\n").count
            if runs < 2 { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(runs == 2)
        let pane = try await fixture.waitForPane("ms-proj-cmd-re") { $0.isDead }
        #expect(pane?.deadStatus == 3)
    }

    @Test func testRespawnOfLivePaneKeepsItAlive() async throws -> Void {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.client.newSession(
            name: "ms-proj-cmd-live", directory: "/tmp",
            command: ["/bin/sh", "-c", "sleep 30"], metadata: fixture.metadata())
        let before = try await fixture.waitForPane("ms-proj-cmd-live") { _ in true }
        try await fixture.client.respawn(session: "ms-proj-cmd-live")
        let after = try await fixture.waitForPane("ms-proj-cmd-live") { $0.pid != before?.pid }
        #expect(after != nil)
        #expect(after?.isDead == false)
    }

    @Test func testSetNameAndKillSession() async throws -> Void {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.client.newSession(
            name: "ms-proj-term-aaaaaa", directory: "/tmp",
            command: ["/bin/sh", "-c", "sleep 30"], metadata: fixture.metadata(kind: .terminal))
        try await fixture.client.setName(session: "ms-proj-term-aaaaaa", name: "Renamed")
        let pane = try await fixture.waitForPane("ms-proj-term-aaaaaa") { $0.name == "Renamed" }
        #expect(pane != nil)
        try await fixture.client.killSession("ms-proj-term-aaaaaa")
        try await fixture.client.killServer()
        #expect(try await fixture.client.listPanes().isEmpty)
    }
}
