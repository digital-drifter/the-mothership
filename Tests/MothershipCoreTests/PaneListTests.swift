import Foundation
import Testing
@testable import MothershipCore

struct PaneListTests {
    @Test func testParsesLivePane() -> Void {
        let line = "ms-proj-cmd-web\t%3\t4242\t1700000000\t0\t\tproj\tcmd\tWeb\t"
        let panes = PaneListFormat.parse(line + "\n")
        #expect(panes.count == 1)
        #expect(panes[0].sessionName == "ms-proj-cmd-web")
        #expect(panes[0].paneID == "%3")
        #expect(panes[0].pid == 4242)
        #expect(panes[0].created == 1_700_000_000)
        #expect(panes[0].isDead == false)
        #expect(panes[0].deadStatus == nil)
        #expect(panes[0].kind == .command)
        #expect(panes[0].project == "proj")
        #expect(panes[0].name == "Web")
        #expect(panes[0].template == "")
    }

    @Test func testParsesDeadPaneWithStatus() -> Void {
        let line = "ms-proj-agent-abc123\t%4\t99\t1700000001\t1\t3\tproj\tagent\tClaude\tclaude"
        let panes = PaneListFormat.parse(line)
        #expect(panes.count == 1)
        #expect(panes[0].isDead)
        #expect(panes[0].deadStatus == 3)
        #expect(panes[0].kind == .agent)
        #expect(panes[0].template == "claude")
    }

    @Test func testSkipsForeignSessionsAndMalformedLines() -> Void {
        let output = [
            "work\t%1\t1\t1\t0\t\t\t\t\t",
            "ms-a\t%2\t3",
            "ms-proj-term-zzzzzz\t%5\t7\t1700000002\t0\t\tproj\tterm\tShell\t",
        ].joined(separator: "\n")
        let panes = PaneListFormat.parse(output)
        #expect(panes.map(\.sessionName) == ["ms-proj-term-zzzzzz"])
    }

    @Test func testLocatorPrefersHomebrew() -> Void {
        let found = TmuxLocator.find(environmentPath: "/x/bin", fileExists: { _ in true })
        #expect(found == "/opt/homebrew/bin/tmux")
    }

    @Test func testLocatorFallsBackToPath() -> Void {
        let found = TmuxLocator.find(environmentPath: "/x/bin:/y", fileExists: { $0 == "/x/bin/tmux" })
        #expect(found == "/x/bin/tmux")
    }

    @Test func testLocatorReturnsNilWhenAbsent() -> Void {
        #expect(TmuxLocator.find(environmentPath: "/x/bin:/y", fileExists: { _ in false }) == nil)
        #expect(TmuxLocator.find(environmentPath: nil, fileExists: { _ in false }) == nil)
    }

    @Test func testConfigContainsRequiredSettings() -> Void {
        let required = [
            "history-limit 50000", "escape-time 0", "default-terminal \"xterm-256color\"",
            "remain-on-exit on", "mouse off", "status off", "window-size latest",
            "set -g prefix None", "unbind C-b",
        ]
        for line in required {
            #expect(TmuxConfig.contents.contains(line), "missing \(line)")
        }
    }
}
