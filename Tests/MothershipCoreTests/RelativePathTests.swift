import XCTest

@testable import MothershipCore

final class RelativePathTests: XCTestCase {
    func testPickingTheProjectRootStoresBlank() -> Void {
        XCTAssertEqual(RelativePath.storedDirectory(picked: "/x/app", projectPath: "/x/app"), "")
        XCTAssertEqual(RelativePath.storedDirectory(picked: "/x/app/", projectPath: "/x/app"), "")
    }

    func testPickingInsideTheProjectStoresARelativePath() -> Void {
        XCTAssertEqual(RelativePath.storedDirectory(picked: "/x/app/frontend/web", projectPath: "/x/app"), "frontend/web")
    }

    func testPickingOutsideTheProjectStoresAnAbsolutePath() -> Void {
        XCTAssertEqual(RelativePath.storedDirectory(picked: "/x/other", projectPath: "/x/app"), "/x/other")
    }

    func testASiblingWithTheSamePrefixIsOutside() -> Void {
        XCTAssertEqual(RelativePath.storedDirectory(picked: "/x/app-old", projectPath: "/x/app"), "/x/app-old")
    }
}
