import Testing
@testable import MothershipCore

@Test func testSlugLowercasesAndHyphenates() -> Void { #expect(Slug.make("API Server") == "api-server") }
@Test func testSlugCollapsesPunctuationAndTrims() -> Void { #expect(Slug.make("  --Vite (dev)!! ") == "vite-dev") }
@Test func testSlugFoldsDiacritics() -> Void { #expect(Slug.make("Café Ünïcode") == "cafe-unicode") }
@Test func testSlugOfOnlySymbolsIsX() -> Void { #expect(Slug.make("🚀🚀") == "x") }
@Test func testSessionNameFormat() -> Void {
    #expect(SessionName.make(projectSlug: "acme", kind: .command, id: "vite") == "ms-acme-cmd-vite")
    #expect(SessionName.make(projectSlug: "p", kind: .terminal, id: "a1b2c3") == "ms-p-term-a1b2c3")
}
@Test func testRandomIDIsSixLowercaseAlphanumerics() -> Void {
    let id = SessionName.randomID()
    #expect(id.count == 6 && id.allSatisfy { $0.isLowercase || $0.isNumber } && id.allSatisfy { $0.isASCII })
}
