import AppKit
import SwiftTerm
import Testing
@testable import Mothership

/// Records what the terminal view would send to the pane.
@MainActor
private final class SendRecorder: TerminalViewDelegate {
    var sent: [[UInt8]] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) -> Void { sent.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) -> Void {}
    func setTerminalTitle(source: TerminalView, title: String) -> Void {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) -> Void {}
    func scrolled(source: TerminalView, position: Double) -> Void {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) -> Void {}
}

@MainActor
private func makeView() -> (PaneTerminalView, SendRecorder) {
    let view = PaneTerminalView(
        frame: NSRect(x: 0, y: 0, width: 400, height: 200),
        font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        options: TerminalOptions(scrollback: 100))
    let recorder = SendRecorder()
    view.terminalDelegate = recorder
    return (view, recorder)
}

/// SwiftTerm hands replies to its delegate on a later main-queue turn; let those run.
@MainActor
private func drainMainQueue() async throws -> Void {
    try await Task.sleep(for: .milliseconds(100))
}

@Suite @MainActor struct PaneTerminalViewTests {
    @Test func testQueriesInPaneOutputAreNotAnsweredAgain() async throws -> Void {
        let (view, recorder) = makeView()
        // DSR cursor position, DA1, DA2 and a DSR status query: tmux has already answered all of them.
        view.feedOutput(Array("\u{1b}[6n\u{1b}[c\u{1b}[>c\u{1b}[5n".utf8)[...])
        try await drainMainQueue()
        #expect(recorder.sent.isEmpty)
    }

    @Test func testMouseReportsStillReachThePane() async throws -> Void {
        let (view, recorder) = makeView()
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.feedOutput(Array("\u{1b}[?1000h".utf8)[...])
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 4, y: view.frame.height - 4), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1))
        view.mouseDown(with: click)
        try await drainMainQueue()
        // X10 mouse report for a left press in the top-left cell: ESC [ M, button 0, column 1, row 1.
        #expect(recorder.sent == [[0x1b, 0x5b, 0x4d, 32, 33, 33]])
    }
}
