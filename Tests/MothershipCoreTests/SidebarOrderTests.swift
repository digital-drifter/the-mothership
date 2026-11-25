import Foundation
import Testing
@testable import MothershipCore

struct SidebarOrderTests {
    @Test func testMovingARowDownMatchesListSemantics() -> Void {
        #expect(SidebarOrder.moving(["a", "b", "c"], from: IndexSet(integer: 0), to: 3) == ["b", "c", "a"])
        #expect(SidebarOrder.moving(["a", "b", "c"], from: IndexSet(integer: 0), to: 2) == ["b", "a", "c"])
    }

    @Test func testMovingARowUp() -> Void {
        #expect(SidebarOrder.moving(["a", "b", "c"], from: IndexSet(integer: 2), to: 0) == ["c", "a", "b"])
    }

    @Test func testMovingOntoItselfChangesNothing() -> Void {
        #expect(SidebarOrder.moving(["a", "b"], from: IndexSet(integer: 1), to: 1) == ["a", "b"])
        #expect(SidebarOrder.moving(["a", "b"], from: IndexSet(integer: 1), to: 2) == ["a", "b"])
    }

    @Test func testMovingWithOffsetsOutOfRangeChangesNothing() -> Void {
        #expect(SidebarOrder.moving(["a", "b"], from: IndexSet(integer: 5), to: 0) == ["a", "b"])
        #expect(SidebarOrder.moving(["a", "b"], from: IndexSet(integer: 0), to: 9) == ["a", "b"])
    }

    @Test func testApplyingPutsSavedFirstThenTheRest() -> Void {
        #expect(SidebarOrder.applying(["c", "gone", "a"], to: ["a", "b", "c", "d"]) == ["c", "a", "b", "d"])
    }
}
