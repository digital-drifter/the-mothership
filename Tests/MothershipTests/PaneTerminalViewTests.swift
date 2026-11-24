import AppKit
import SwiftTerm
import Testing
import MothershipCore
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

    /// Live output is parsed on the control client's background queue, not the main thread.
    @Test func testQueriesFedFromABackgroundThreadAreNotAnsweredAgain() async throws -> Void {
        let (view, recorder) = makeView()
        let bytes = Array("\u{1b}[6n\u{1b}[c\u{1b}[>c\u{1b}[5n".utf8)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                view.feedOutput(bytes[...])
                continuation.resume()
            }
        }
        try await drainMainQueue()
        #expect(recorder.sent.isEmpty)
    }

    @Test func testOutputFedFromABackgroundThreadReachesTheScreenInOrder() async throws -> Void {
        let (view, _) = makeView()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                for index in 0..<200 { view.feedOutput(Array("line-\(index)\r\n".utf8)[...]) }
                continuation.resume()
            }
        }
        try await drainMainQueue()
        let text = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
        let first = try #require(text.range(of: "line-150"))
        let second = try #require(text.range(of: "line-199"))
        #expect(first.lowerBound < second.lowerBound)
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

@Suite @MainActor struct PaneTerminalViewSeedTests {
    @Test func testReseedAfterRespawnDropsAlternateScreenAndMouseModes() async throws -> Void {
        let (view, recorder) = makeView()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        // The pane was running a full-screen program with mouse reporting on...
        view.feedOutput(SeedBuilder.build(PaneSnapshot(
            historyAndScreen: ["$ vim"], alternateScreen: ["~ VIM"], cursorX: 0, cursorY: 0,
            mouseStandard: true, mouseSGR: true))[...])
        // ...then respawn-pane reset it, and the reseed shows a fresh shell.
        view.feedOutput(SeedBuilder.build(PaneSnapshot(historyAndScreen: ["$ "], cursorX: 2, cursorY: 0))[...])
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 4, y: view.frame.height - 4), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1))
        view.mouseDown(with: click)
        try await drainMainQueue()
        #expect(recorder.sent.isEmpty)
        let text = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
        #expect(!String(decoding: view.getBufferAsData(kind: .active), as: UTF8.self).contains("VIM"))
        #expect(!text.contains("vim"))
    }
}

/// Records every delegate callback and whether it ran on the main thread.
@MainActor
private final class ThreadRecorder: TerminalViewDelegate {
    var callbacks = 0
    var offMain = 0

    private func note() -> Void {
        callbacks += 1
        if !Thread.isMainThread { offMain += 1 }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) -> Void { note() }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) -> Void { note() }
    func setTerminalTitle(source: TerminalView, title: String) -> Void { note() }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) -> Void { note() }
    func scrolled(source: TerminalView, position: Double) -> Void { note() }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) -> Void { note() }
    func bell(source: TerminalView) -> Void { note() }
}

@Suite @MainActor struct PaneTerminalViewConcurrencyTests {
    /// Pane output is untrusted and is parsed on a background thread while the main thread draws,
    /// resizes and handles input. Everything the emulator calls back must still arrive on the main thread.
    @Test func testBackgroundParsingWhileTheMainThreadUsesTheViewIsSafe() async throws -> Void {
        let view = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            options: TerminalOptions(scrollback: 500))
        let recorder = ThreadRecorder()
        view.terminalDelegate = recorder
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view

        // Sequences that make the emulator call its delegate or reply: title, working directory, bell,
        // device queries, clipboard write, mouse mode, alternate screen, scrolling text, and junk.
        let chunks: [[UInt8]] = [
            Array("\u{1b}]0;title\u{07}".utf8), Array("\u{1b}]7;file://host/tmp/x\u{07}".utf8), [0x07],
            Array("\u{1b}[6n\u{1b}[c\u{1b}[>c\u{1b}[5n\u{1b}[18t".utf8),
            Array("\u{1b}]52;c;aGVsbG8=\u{07}".utf8), Array("\u{1b}[?1000h\u{1b}[?1006h".utf8),
            Array("\u{1b}[?1049h full screen \u{1b}[?1049l".utf8),
            Array((0..<40).map { "line \($0) of scrolling output\r\n" }.joined().utf8),
            [0x1b, 0x5b, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x3b, 0xff, 0xfe, 0x00, 0x1b, 0x50, 0x9c],
        ]
        let feeding = Task.detached {
            for round in 0..<300 { view.feedOutput(chunks[round % chunks.count][...]) }
        }
        // Meanwhile, on the main thread: resize, read the buffer, click.
        for step in 0..<60 {
            view.setFrameSize(NSSize(width: 300 + (step % 7) * 20, height: 150 + (step % 5) * 20))
            _ = view.getBufferAsData(kind: .active)
            if let click = NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 4, y: 4), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                view.mouseDown(with: click)
            }
            await Task.yield()
        }
        await feeding.value
        try await drainMainQueue()
        #expect(recorder.callbacks > 0)
        #expect(recorder.offMain == 0)
    }
}
