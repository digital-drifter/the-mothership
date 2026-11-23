import Foundation
import Testing
@testable import MothershipCore

private let home = "/Users/test"

private let fullExample = """
projects:
  - name: Acme
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

@Test func testParsesFullExample() throws -> Void {
    let config = try ConfigLoader.parse(fullExample, homeDirectory: home)
    #expect(config.projects.count == 1)
    let project = config.projects[0]
    #expect(project.name == "Acme")
    #expect(project.slug == "acme")
    #expect(project.path == "/Users/test/Code/es")
    #expect(project.commands.map(\.name) == ["Vite", "Queue"])
    #expect(project.commands[0].slug == "vite")
    #expect(project.commands[0].autostart == true)
    #expect(project.commands[1].autostart == false)
    #expect(project.agents == [AgentTemplate(name: "Claude", run: "claude")])
}

@Test func testEmptyOrCommentOnlyFileHasNoProjects() throws -> Void {
    #expect(try ConfigLoader.parse("", homeDirectory: home).projects == [])
    #expect(try ConfigLoader.parse(ConfigLoader.exampleYAML, homeDirectory: home).projects == [])
}

@Test func testMissingPathIsReported() -> Void {
    #expect(throws: ConfigError.missingField("projects[0].path")) {
        try ConfigLoader.parse("projects:\n  - name: A\n", homeDirectory: home)
    }
}

@Test func testMissingNameIsReported() -> Void {
    #expect(throws: ConfigError.missingField("projects[0].name")) {
        try ConfigLoader.parse("projects:\n  - path: /a\n", homeDirectory: home)
    }
}

@Test func testMissingRunIsReported() -> Void {
    let yaml = "projects:\n  - name: A\n    path: /a\n    commands:\n      - name: X\n"
    #expect(throws: ConfigError.missingField("projects[0].commands[0].run")) {
        try ConfigLoader.parse(yaml, homeDirectory: home)
    }
}

@Test func testDuplicateProjectSlugsRejected() -> Void {
    let yaml = "projects:\n  - name: API Server\n    path: /a\n  - name: api-server\n    path: /b\n"
    do {
        _ = try ConfigLoader.parse(yaml, homeDirectory: home)
        Issue.record("expected duplicateName")
    } catch let ConfigError.duplicateName(message) {
        #expect(message.contains("api-server"))
        #expect(message == "Two projects share the slug \"api-server\": \"API Server\", \"api-server\"")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func testDuplicateCommandSlugsInOneProjectRejected() -> Void {
    let yaml = """
    projects:
      - name: A
        path: /a
        commands:
          - {name: Dev Server, run: x}
          - {name: dev-server, run: y}
    """
    #expect(throws: ConfigError.self) { try ConfigLoader.parse(yaml, homeDirectory: home) }
}

@Test func testSameCommandNameInDifferentProjectsAllowed() throws -> Void {
    let yaml = """
    projects:
      - name: A
        path: /a
        commands: [{name: Vite, run: x}]
      - name: B
        path: /b
        commands: [{name: Vite, run: x}]
    """
    #expect(try ConfigLoader.parse(yaml, homeDirectory: home).projects.count == 2)
}

@Test func testMalformedYAMLThrowsInvalidYAML() -> Void {
    do {
        _ = try ConfigLoader.parse("projects: [", homeDirectory: home)
        Issue.record("expected invalidYAML")
    } catch ConfigError.invalidYAML {
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func testEnsureExistsCreatesExampleOnce() throws -> Void {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("nested/projects.yml")
    try ConfigLoader.ensureExists(at: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == ConfigLoader.exampleYAML)
    try "edited".write(to: url, atomically: true, encoding: .utf8)
    try ConfigLoader.ensureExists(at: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "edited")
}

@Test func testControlCharactersInNamesBecomeSpaces() throws -> Void {
    // Names end up in tmux's tab-separated, line-based list-panes output, so they must not hold either.
    let yaml = """
    projects:
      - name: "Event\\tSprout"
        path: ~/Code/es
        commands:
          - name: "Vite\\ndev"
            run: npm run dev
        agents:
          - name: "Claude\\u0007Code"
            run: claude
    """
    let project = try #require(try ConfigLoader.parse(yaml, homeDirectory: home).projects.first)
    #expect(project.name == "Event Sprout")
    #expect(project.commands.map(\.name) == ["Vite dev"])
    #expect(project.agents.map(\.name) == ["Claude Code"])
}
