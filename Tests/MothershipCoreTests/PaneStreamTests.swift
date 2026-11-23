import Foundation
import Testing
@testable import MothershipCore

/// Records sent lines and lets a test push events as if they came from tmux.
private final class FakeChannel: ControlChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ControlEvent) -> Void)?
    private var lines: [String] = []

    var onEvent: (@Sendable (ControlEvent) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    var sent: [String] { lock.withLock { lines } }

    func send(_ commandLine: String) -> Void {
        lock.withLock { lines.append(commandLine) }
    }

    func command(_ commandLine: String) async throws -> [String] {
        throw ControlClientError.notRunning
    }

    func push(_ event: ControlEvent) -> Void {
        onEvent?(event)
    }
}

private final class ByteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UInt8]] = []

    var chunks: [[UInt8]] { lock.withLock { items } }

    func append(_ bytes: [UInt8]) -> Void {
        lock.withLock { items.append(bytes) }
    }
}

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

// Header fields: alternate, cursor x/y, saved x/y, cursor visible, keypad, bracketed paste,
// mouse standard/button/all/sgr, history size, pane id.

/// The reply blocks tmux sends for `SeedBuilder.snapshotCommand`, normal screen, no history.
private func snapshotReplies(paneID: String, screen: [String], cursorX: Int = 0, cursorY: Int = 0) -> [ControlEvent] {
    [
        .reply(number: 10, lines: [SeedBuilder.marker], isError: false),
        .reply(number: 11, lines: ["0 \(cursorX) \(cursorY) 4294967295 4294967295 1 0 0 0 0 0 0 0 \(paneID)"], isError: false),
        .reply(number: 12, lines: [screen.first ?? ""], isError: false),  // -E -1 with no history: ignored
        .reply(number: 13, lines: [""], isError: false),  // -a -q with no alternate screen
        .reply(number: 14, lines: screen, isError: false),
    ]
}

/// A snapshot whose header command failed (e.g. the target is gone): the marker, then four errors.
private func failedSnapshotReplies() -> [ControlEvent] {
    [.reply(number: 20, lines: [SeedBuilder.marker], isError: false)]
        + (21...24).map { .reply(number: $0, lines: ["can't find pane: ms-p-cmd-x"], isError: true) }
}

private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    var messages: [String] { lock.withLock { items } }

    func append(_ message: String) -> Void {
        lock.withLock { items.append(message) }
    }
}

private func makeStream() -> (FakeChannel, PaneStream, ByteLog) {
    let channel = FakeChannel()
    let stream = PaneStream(channel: channel, target: "ms-p-cmd-x")
    let log = ByteLog()
    stream.onBytes = { log.append($0) }
    return (channel, stream, log)
}

@Suite struct PaneStreamTests {
    @Test func testAttachSendsResizeThenSnapshotCommand() -> Void {
        let (channel, stream, _) = makeStream()
        stream.attach(cols: 120, rows: 40)
        #expect(channel.sent == ["refresh-client -C 120x40", SeedBuilder.snapshotCommand(target: "ms-p-cmd-x")])
    }

    @Test func testSnapshotCommandIsOneTmuxCommandPerLine() -> Void {
        let lines = SeedBuilder.snapshotCommand(target: "ms-p-cmd-x").split(separator: "\n")
        #expect(lines.count == SeedBuilder.snapshotReplyCount)
        #expect(!lines[0].contains("-t "))  // the marker must not depend on the target
        #expect(lines.dropFirst().allSatisfy { $0.contains("-t ms-p-cmd-x") })
        #expect(lines.allSatisfy { !$0.contains(" ; ") })
    }

    @Test func testOutputBeforeSnapshotIsDroppedAndAfterIsForwarded() -> Void {
        let (channel, stream, log) = makeStream()
        stream.attach(cols: 80, rows: 24)
        channel.push(.reply(number: 1, lines: [], isError: false))  // attach block
        channel.push(.reply(number: 2, lines: [], isError: false))  // refresh-client
        channel.push(.output(paneID: "%1", data: bytes("A")))
        snapshotReplies(paneID: "%1", screen: ["$ A"], cursorX: 3).forEach(channel.push)
        channel.push(.output(paneID: "%1", data: bytes("B")))
        let seed = SeedBuilder.build(PaneSnapshot(paneID: "%1", historyAndScreen: ["$ A"], cursorX: 3, cursorY: 0))
        #expect(log.chunks == [seed, bytes("B")])
    }

    @Test func testOutputForOtherPanesIgnored() -> Void {
        let (channel, stream, log) = makeStream()
        stream.attach(cols: 80, rows: 24)
        snapshotReplies(paneID: "%1", screen: ["$"]).forEach(channel.push)
        channel.push(.output(paneID: "%2", data: bytes("other")))
        channel.push(.output(paneID: "%1", data: bytes("mine")))
        #expect(log.chunks.count == 2)
        #expect(log.chunks.last == bytes("mine"))
    }

    @Test func testFailedSnapshotIsReissuedOnceAndThenSeeds() -> Void {
        let (channel, stream, log) = makeStream()
        let failures = FailureLog()
        stream.onFailure = { failures.append($0) }
        stream.attach(cols: 80, rows: 24)
        failedSnapshotReplies().forEach(channel.push)
        channel.push(.output(paneID: "%1", data: bytes("dropped")))
        let snapshot = SeedBuilder.snapshotCommand(target: "ms-p-cmd-x")
        #expect(channel.sent == ["refresh-client -C 80x24", snapshot, snapshot])
        #expect(log.chunks.isEmpty)
        snapshotReplies(paneID: "%1", screen: ["$"]).forEach(channel.push)
        channel.push(.output(paneID: "%1", data: bytes("kept")))
        #expect(log.chunks.count == 2)
        #expect(log.chunks.last == bytes("kept"))
        #expect(failures.messages.isEmpty)
    }

    @Test func testSecondFailedSnapshotReportsFailure() -> Void {
        let (channel, stream, log) = makeStream()
        let failures = FailureLog()
        stream.onFailure = { failures.append($0) }
        stream.attach(cols: 80, rows: 24)
        failedSnapshotReplies().forEach(channel.push)
        failedSnapshotReplies().forEach(channel.push)
        #expect(failures.messages == ["can't find pane: ms-p-cmd-x"])
        #expect(channel.sent.count == 3)  // resize, snapshot, one re-issue; no third attempt
        snapshotReplies(paneID: "%1", screen: ["$"]).forEach(channel.push)
        channel.push(.output(paneID: "%1", data: bytes("late")))
        #expect(log.chunks.isEmpty)
    }

    @Test func testBlocksOfAFailedSnapshotAreNeverReadAsAMarker() -> Void {
        let (channel, stream, log) = makeStream()
        stream.attach(cols: 80, rows: 24)
        // Header fails; the captures that follow happen to contain exactly the marker text.
        channel.push(.reply(number: 1, lines: [SeedBuilder.marker], isError: false))
        channel.push(.reply(number: 2, lines: ["boom"], isError: true))
        channel.push(.reply(number: 3, lines: [SeedBuilder.marker], isError: false))
        channel.push(.reply(number: 4, lines: [SeedBuilder.marker], isError: false))
        channel.push(.reply(number: 5, lines: [SeedBuilder.marker], isError: false))
        #expect(log.chunks.isEmpty)
        #expect(channel.sent.count == 3)  // counted down all five blocks, then re-issued
        snapshotReplies(paneID: "%1", screen: ["$"]).forEach(channel.push)
        #expect(log.chunks.count == 1)
    }

    @Test func testSeedForNormalScreenPlacesCursor() -> Void {
        let snapshot = PaneSnapshot(historyAndScreen: ["$ ls", "a b"], cursorX: 2, cursorY: 1)
        #expect(SeedBuilder.build(snapshot) == bytes("\u{1b}c\u{1b}[?25h$ ls\r\na b\u{1b}[2;3H"))
    }

    @Test func testSeedStartsWithAFullResetSoItReplacesWhateverWasShown() -> Void {
        // A seed is also fed into a view that already shows the pane (after a respawn or reconnect):
        // RIS drops the old screen, scrollback and modes; RIS keeps cursor visibility, so show it.
        let seed = String(decoding: SeedBuilder.build(PaneSnapshot(historyAndScreen: ["x"], cursorX: 0, cursorY: 0)), as: UTF8.self)
        #expect(seed.hasPrefix("\u{1b}c\u{1b}[?25h"))
    }

    @Test func testSeedForAlternateScreenSwitchesBuffers() -> Void {
        let snapshot = PaneSnapshot(
            historyAndScreen: ["hist"], alternateScreen: ["alt1", "alt2"], cursorX: 0, cursorY: 0,
            savedCursorX: 4, savedCursorY: 2)
        let seed = String(decoding: SeedBuilder.build(snapshot), as: UTF8.self)
        // The saved normal-screen cursor is placed just before ?1049h saves it.
        #expect(seed == "\u{1b}c\u{1b}[?25hhist\u{1b}[3;5H\u{1b}[?1049h\u{1b}[Halt1\r\nalt2\u{1b}[1;1H")
    }

    @Test func testSeedRestoresMouseAndKeypadModes() -> Void {
        var snapshot = PaneSnapshot(historyAndScreen: ["x"], cursorX: 0, cursorY: 0)
        snapshot.keypadCursor = true
        snapshot.mouseStandard = true
        snapshot.mouseButton = true
        snapshot.mouseAll = true
        snapshot.mouseSGR = true
        snapshot.bracketedPaste = true
        snapshot.cursorVisible = false
        let seed = String(decoding: SeedBuilder.build(snapshot), as: UTF8.self)
        #expect(seed.hasSuffix(
            "\u{1b}[1;1H\u{1b}[?1h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?25l"))
        snapshot = PaneSnapshot(historyAndScreen: ["x"], cursorX: 0, cursorY: 0, mouseButton: true)
        #expect(String(decoding: SeedBuilder.build(snapshot), as: UTF8.self).hasSuffix("x\u{1b}[1;1H\u{1b}[?1002h"))
        snapshot.mouseButton = false
        #expect(String(decoding: SeedBuilder.build(snapshot), as: UTF8.self).hasSuffix("x\u{1b}[1;1H"))
    }

    @Test func testSendInputHexEncodesAndChunks() -> Void {
        let (channel, stream, _) = makeStream()
        let input = (0..<3000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        stream.sendInput(input)
        let prefix = "send-keys -H -t ms-p-cmd-x "
        #expect(channel.sent.count == 3)
        var decoded: [UInt8] = []
        for line in channel.sent {
            #expect(line.hasPrefix(prefix))
            let chunk = line.dropFirst(prefix.count).split(separator: " ").compactMap { UInt8($0, radix: 16) }
            #expect(chunk.count <= 1024)
            decoded += chunk
        }
        #expect(decoded == input)
    }

    @Test func testResizeSendsRefreshClient() -> Void {
        let (channel, stream, _) = makeStream()
        stream.resize(cols: 100, rows: 30)
        #expect(channel.sent == ["refresh-client -C 100x30"])
    }

    @Test func testParseSnapshotRejectsUnrelatedReply() -> Void {
        #expect(SeedBuilder.parseSnapshot([["hello"]]) == nil)
        #expect(SeedBuilder.parseSnapshot([["hello"], ["a"], ["b"], ["c"], ["d"]]) == nil)
        #expect(SeedBuilder.parseSnapshot([[SeedBuilder.marker], ["x y"], [], [], []]) == nil)
        let valid = snapshotReplies(paneID: "%1", screen: ["$"]).compactMap { event -> [String]? in
            if case let .reply(_, lines, _) = event { return lines }
            return nil
        }
        #expect(SeedBuilder.parseSnapshot(Array(valid.prefix(4))) == nil)
        #expect(SeedBuilder.parseSnapshot(valid) != nil)
    }

    @Test func testParseSnapshotOfNormalScreenCombinesHistoryAndScreen() -> Void {
        let snapshot = SeedBuilder.parseSnapshot([
            [SeedBuilder.marker], ["0 4 1 4294967295 4294967295 0 1 1 1 0 1 1 2 %7"], ["h1", "h2"], [""], ["s1", "s2"],
        ])
        #expect(snapshot == PaneSnapshot(
            paneID: "%7", historyAndScreen: ["h1", "h2", "s1", "s2"], alternateScreen: nil,
            cursorX: 4, cursorY: 1, savedCursorX: 0, savedCursorY: 0, cursorVisible: false,
            keypadCursor: true, bracketedPaste: true,
            mouseStandard: true, mouseButton: false, mouseAll: true, mouseSGR: true))
    }

    @Test func testParseSnapshotIgnoresHistoryBlockWhenHistoryIsEmpty() -> Void {
        let snapshot = SeedBuilder.parseSnapshot([
            [SeedBuilder.marker], ["0 0 0 0 0 1 0 0 0 0 0 0 0 %1"], ["s1"], [""], ["s1", "s2"],
        ])
        #expect(snapshot?.historyAndScreen == ["s1", "s2"])
    }

    @Test func testParseSnapshotOfAlternateScreenUsesSavedNormalScreen() -> Void {
        let snapshot = SeedBuilder.parseSnapshot([
            [SeedBuilder.marker], ["1 0 0 5 3 1 0 0 0 1 0 0 1 %2"], ["h1"], ["saved1", "saved2"], ["alt1"],
        ])
        #expect(snapshot?.historyAndScreen == ["h1", "saved1", "saved2"])
        #expect(snapshot?.alternateScreen == ["alt1"])
        #expect(snapshot?.savedCursorX == 5)
        #expect(snapshot?.savedCursorY == 3)
        #expect(snapshot?.mouseButton == true)
    }
}
