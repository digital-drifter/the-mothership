import Testing

@testable import MothershipCore

@Suite struct RelativePathTests {
    @Test func testPickingTheProjectRootStoresBlank() -> Void {
        #expect(RelativePath.storedDirectory(picked: "/x/app", projectPath: "/x/app") == "")
        #expect(RelativePath.storedDirectory(picked: "/x/app/", projectPath: "/x/app") == "")
    }

    @Test func testPickingInsideTheProjectStoresARelativePath() -> Void {
        #expect(RelativePath.storedDirectory(picked: "/x/app/frontend/web", projectPath: "/x/app") == "frontend/web")
    }

    @Test func testPickingOutsideTheProjectStoresAnAbsolutePath() -> Void {
        #expect(RelativePath.storedDirectory(picked: "/x/other", projectPath: "/x/app") == "/x/other")
    }

    @Test func testASiblingWithTheSamePrefixIsOutside() -> Void {
        #expect(RelativePath.storedDirectory(picked: "/x/app-old", projectPath: "/x/app") == "/x/app-old")
    }
}
