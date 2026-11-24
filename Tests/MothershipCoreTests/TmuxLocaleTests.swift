import Foundation
import Testing
@testable import MothershipCore

@Suite struct TmuxLocaleTests {
    @Test func testAnEnvironmentWithoutALocaleGetsAUTF8One() -> Void {
        let environment = TmuxLocale.environment(from: ["HOME": "/Users/x", "PATH": "/usr/bin"])
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["HOME"] == "/Users/x")
    }

    @Test func testAnExistingUTF8LocaleIsLeftAlone() -> Void {
        for existing in [["LANG": "de_DE.UTF-8"], ["LC_CTYPE": "UTF-8"], ["LC_ALL": "fr_FR.utf8"], ["LANG": "C.UTF-8"]] {
            #expect(TmuxLocale.environment(from: existing) == existing)
        }
    }

    @Test func testANonUTF8LocaleIsReplaced() -> Void {
        #expect(TmuxLocale.environment(from: ["LANG": "C"])["LANG"] == "en_US.UTF-8")
        #expect(TmuxLocale.environment(from: ["LANG": ""])["LANG"] == "en_US.UTF-8")
    }
}

private let tmuxPath: String? = TmuxLocator.find(environmentPath: ProcessInfo.processInfo.environment["PATH"])

/// Apps opened from the Dock or Finder get no locale. Without one tmux replaces the tabs in its
/// output with underscores, and the pane list parses to nothing.
@Suite(.enabled(if: tmuxPath != nil))
struct TmuxBareEnvironmentTests {
    @Test func testPanesAreListedWhenTheAppWasLaunchedWithoutALocale() async throws -> Void {
        let path = try #require(tmuxPath)
        let socket = "ms-test-\(UUID().uuidString.prefix(8))"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = try TmuxConfig.install(in: directory)
        let bare = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let client = TmuxClient(tmuxPath: path, configPath: config.path, socketName: socket, environment: bare)
        defer {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: path)
            kill.arguments = ["-L", socket, "kill-server"]
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
            kill.waitUntilExit()
            removeTmuxSocket(named: socket)
            try? FileManager.default.removeItem(at: directory)
        }
        try await client.newSession(
            name: "ms-proj-cmd-web", directory: "/tmp", command: ["/bin/sh", "-c", "sleep 30"],
            metadata: SessionMetadata(project: "proj", kind: .command, name: "Café ✓", template: ""))
        let panes = try await client.listPanes()
        #expect(panes.count == 1)
        #expect(panes.first?.kind == .command)
        #expect(panes.first?.name == "Café ✓")
    }
}
