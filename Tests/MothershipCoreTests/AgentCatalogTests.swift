import Testing
@testable import MothershipCore

struct AgentCatalogTests {
    @Test func testCatalogListsTheKnownAgentsInOrder() throws -> Void {
        #expect(AgentCatalog.all.map(\.id) == ["claude", "codex", "gemini", "copilot", "cursor", "aider", "opencode", "amp"])
        let cursor = try #require(AgentCatalog.all.first { $0.id == "cursor" })
        #expect(cursor.run == "cursor-agent")
        let claude = try #require(AgentCatalog.all.first { $0.id == "claude" })
        #expect(claude.name == "Claude Code")
    }
}
