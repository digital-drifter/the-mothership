import Testing
@testable import MothershipCore

private func pane(_ session: String, pid: Int32, dead: Bool = false) -> PaneInfo {
    PaneInfo(
        sessionName: session, paneID: "%1", pid: pid, created: 1, isDead: dead, deadStatus: dead ? 0 : nil,
        project: "p", kind: .command, name: "x", template: "")
}

@Suite struct RespawnTrackerTests {
    @Test func testFirstSightingIsNotARespawn() -> Void {
        var tracker = RespawnTracker()
        #expect(tracker.update([pane("ms-p-cmd-a", pid: 10), pane("ms-p-cmd-b", pid: 0, dead: true)]).isEmpty)
    }

    @Test func testNewPidOfALivePaneIsARespawn() -> Void {
        var tracker = RespawnTracker()
        _ = tracker.update([pane("ms-p-cmd-a", pid: 10)])
        #expect(tracker.update([pane("ms-p-cmd-a", pid: 10)]).isEmpty)
        #expect(tracker.update([pane("ms-p-cmd-a", pid: 11)]) == ["ms-p-cmd-a"])
        #expect(tracker.update([pane("ms-p-cmd-a", pid: 11)]).isEmpty)
    }

    @Test func testDeadPaneComingBackToLifeIsARespawn() -> Void {
        var tracker = RespawnTracker()
        _ = tracker.update([pane("ms-p-cmd-a", pid: 0, dead: true)])
        #expect(tracker.update([pane("ms-p-cmd-a", pid: 0, dead: true)]).isEmpty)
        #expect(tracker.update([pane("ms-p-cmd-a", pid: 12)]) == ["ms-p-cmd-a"])
    }

    @Test func testDyingIsNotARespawn() -> Void {
        var tracker = RespawnTracker()
        _ = tracker.update([pane("ms-p-cmd-a", pid: 10)])
        #expect(tracker.update([pane("ms-p-cmd-a", pid: 0, dead: true)]).isEmpty)
    }

    @Test func testSessionRecreatedAfterItWasGoneIsNotARespawn() -> Void {
        var tracker = RespawnTracker()
        _ = tracker.update([pane("ms-p-cmd-a", pid: 10)])
        _ = tracker.update([])
        #expect(tracker.update([pane("ms-p-cmd-a", pid: 20)]).isEmpty)
    }
}
