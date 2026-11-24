import Foundation
import Testing
@testable import MothershipCore

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ms-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) throws -> Date {
    let components = DateComponents(
        calendar: Calendar.current, timeZone: TimeZone.current,
        year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    return try #require(components.date)
}

struct ProjectStoreTests {
    @Test func testLoadWithNoFileReturnsDefaultsAndNoWarning() throws -> Void {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("projects.json")
        let loaded = ProjectStore(url: url).load()
        #expect(loaded.config == .empty)
        #expect(loaded.warning == nil)
        #expect(loaded.canSave)
        #expect(MothershipConfig.empty.agents == [
            AgentTemplate(name: "Claude", run: "claude"), AgentTemplate(name: "Codex", run: "codex"),
        ])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func testSaveThenLoadRoundTrips() throws -> Void {
        let store = ProjectStore(url: try makeDirectory().appendingPathComponent("projects.json"))
        let config = MothershipConfig(
            version: 1,
            agents: [AgentTemplate(name: "Aider", run: "aider --model sonnet")],
            projects: [
                ProjectConfig(
                    slug: "es", name: "ES", path: "/tmp/es",
                    commands: [CommandConfig(slug: "vite", name: "Vite", run: "npm run dev", autostart: true)])
            ])
        try store.save(config)
        let loaded = store.load()
        #expect(loaded.config == config)
        #expect(loaded.warning == nil)
    }

    @Test func testSaveCreatesTheParentDirectoryAndWritesVersion1() throws -> Void {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("nested/projects.json")
        try ProjectStore(url: url).save(.empty)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("nested").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["version"] as? Int == 1)
    }

    @Test func testUnreadableFileIsKeptAsideAndNeverOverwritten() throws -> Void {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("projects.json")
        let original = Data(#"{"version": 1, "projects": ["#.utf8)
        try original.write(to: url)
        let store = ProjectStore(url: url)

        let loaded = store.load(now: try localDate(2026, 11, 23, 16, 5, 9))

        let kept = directory.appendingPathComponent("projects.json.unreadable-20261123-160509")
        #expect(loaded.config == .empty)
        #expect(loaded.canSave)
        #expect(loaded.warning?.contains("projects.json.unreadable-20261123-160509") == true)
        #expect(try Data(contentsOf: kept) == original)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try store.save(.empty)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: kept) == original)
    }

    @Test func testAnUnreadableFileThatCannotBeMovedAsideBlocksSaving() throws -> Void {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("projects.json")
        try Data("not json".utf8).write(to: url)
        // A read-only folder lets the file be read but not renamed.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let loaded = ProjectStore(url: url).load()

        #expect(loaded.config == .empty)
        #expect(!loaded.canSave)
        #expect(loaded.warning?.contains("could not be moved aside") == true)
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }

    @Test(arguments: [#"{"agents":[],"projects":[]}"#, #"{"version":2,"agents":[],"projects":[]}"#])
    func testMissingOrUnknownVersionIsUnreadable(_ text: String) throws -> Void {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("projects.json")
        try Data(text.utf8).write(to: url)

        let loaded = ProjectStore(url: url).load()

        #expect(loaded.config == .empty)
        #expect(loaded.warning != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 1)
        #expect(names.first?.hasPrefix("projects.json.unreadable-") == true)
    }

    @Test func testUnknownFieldsAreIgnored() throws -> Void {
        let url = try makeDirectory().appendingPathComponent("projects.json")
        let text = """
        {
          "version": 1,
          "theme": "dark",
          "agents": [{ "name": "Claude", "run": "claude" }],
          "projects": [
            { "slug": "es", "name": "ES", "path": "/tmp/es", "theme": "dark", "commands": [] }
          ]
        }
        """
        try Data(text.utf8).write(to: url)

        let loaded = ProjectStore(url: url).load()

        #expect(loaded.warning == nil)
        #expect(loaded.config.projects.map(\.slug) == ["es"])
    }

    @Test func testCommandDirectoryRoundTripsAndIsOmittedWhenNil() throws -> Void {
        let url = try makeDirectory().appendingPathComponent("projects.json")
        let store = ProjectStore(url: url)
        func config(_ directory: String?) -> MothershipConfig {
            MothershipConfig(version: 1, agents: [], projects: [
                ProjectConfig(slug: "es", name: "ES", path: "/tmp/es", commands: [
                    CommandConfig(slug: "vite", name: "Vite", run: "npm run dev", autostart: true, directory: directory)
                ])
            ])
        }
        try store.save(config("frontend"))
        #expect(store.load().config.projects[0].commands[0].directory == "frontend")
        try store.save(config(nil))
        #expect(store.load().config.projects[0].commands[0].directory == nil)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("\"directory\""))
    }

    @Test func testWorkingDirectoryResolvesBlankRelativeAndAbsolute() -> Void {
        let project = ProjectConfig(slug: "p", name: "P", path: "/p", commands: [])
        func resolved(_ directory: String?) -> String {
            project.workingDirectory(for: CommandConfig(slug: "c", name: "C", run: "x", autostart: false, directory: directory))
        }
        #expect(resolved(nil) == "/p")
        #expect(resolved("  ") == "/p")
        #expect(resolved("frontend") == "/p/frontend")
        #expect(resolved("a/../b") == "/p/b")
        #expect(resolved("/abs/x") == "/abs/x")
        #expect(resolved("~/x") == NSHomeDirectory() + "/x")
        #expect(ProjectConfig.resolve(directory: "~", projectPath: "/p") == NSHomeDirectory())
        #expect(ProjectConfig.resolve(directory: nil, projectPath: "/q") == "/q")
    }
}
