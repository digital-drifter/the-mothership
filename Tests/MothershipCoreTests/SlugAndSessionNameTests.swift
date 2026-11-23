import Testing
@testable import MothershipCore

@Test func testSlugLowercasesAndHyphenates() -> Void { #expect(Slug.make("API Server") == "api-server") }
@Test func testSlugCollapsesPunctuationAndTrims() -> Void { #expect(Slug.make("  --Vite (dev)!! ") == "vite-dev") }
@Test func testSlugFoldsDiacritics() -> Void { #expect(Slug.make("Café Ünïcode") == "cafe-unicode") }
@Test func testSlugOfOnlySymbolsIsX() -> Void { #expect(Slug.make("🚀🚀") == "x") }
@Test func testSlugUsesTheFallbackWhenNothingIsLeft() -> Void { #expect(Slug.make("🚀🚀", fallback: "project") == "project") }
@Test func testUniqueSlugAppendsTheFirstFreeNumber() -> Void {
    #expect(Slug.unique("App", fallback: "project", taken: ["app", "app-2"]) == "app-3")
}
@Test func testUniqueSlugKeepsAFreeSlug() -> Void { #expect(Slug.unique("App", fallback: "project", taken: []) == "app") }
@Test func testSessionNameFormat() -> Void {
    #expect(SessionName.make(projectSlug: "acme", kind: .command, id: "vite") == "ms-acme-cmd-vite")
    #expect(SessionName.make(projectSlug: "p", kind: .terminal, id: "a1b2c3") == "ms-p-term-a1b2c3")
}
@Test func testSessionTargetMatchesTheExactName() -> Void {
    // `=` turns off tmux's prefix matching; the trailing `:` makes it valid where a pane is expected.
    #expect(SessionName.target("ms-p-cmd-vite") == "=ms-p-cmd-vite:")
}
@Test func testRandomIDIsSixLowercaseAlphanumerics() -> Void {
    let id = SessionName.randomID()
    #expect(id.count == 6 && id.allSatisfy { $0.isLowercase || $0.isNumber } && id.allSatisfy { $0.isASCII })
}
