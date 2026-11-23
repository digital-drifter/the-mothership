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

/// The four reply blocks tmux sends for `SeedBuilder.snapshotCommand`, normal screen, no history.
private func snapshotReplies(paneID: String, screen: [String], cursorX: Int = 0, cursorY: Int = 0) -> [ControlEvent] {
    [
        .reply(number: 10, lines: ["---ms-snapshot--- 0 \(cursorX) \(cursorY) 0 0 0 0 \(paneID)"], isError: false),
        .reply(number: 11, lines: [screen.first ?? ""], isError: false),  // -E -1 with no history: ignored
        .reply(number: 12, lines: [""], isError: false),  // -a -q with no alternate screen
        .reply(number: 13, lines: screen, isError: false),
    ]
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
        #expect(lines.allSatisfy { $0.contains("-t ms-p-cmd-x") && !$0.contains(" ; ") })
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

    @Test func testErrorDuringSnapshotKeepsWaitingForAFullSnapshot() -> Void {
        let (channel, stream, log) = makeStream()
        stream.attach(cols: 80, rows: 24)
        let replies = snapshotReplies(paneID: "%1", screen: ["$"])
        channel.push(replies[0])
        channel.push(.reply(number: 11, lines: ["can't find pane"], isError: true))
        channel.push(.output(paneID: "%1", data: bytes("dropped")))
        #expect(log.chunks.isEmpty)
        replies.forEach(channel.push)
        channel.push(.output(paneID: "%1", data: bytes("kept")))
        #expect(log.chunks.count == 2)
        #expect(log.chunks.last == bytes("kept"))
    }

    @Test func testSeedForNormalScreenPlacesCursor() -> Void {
        let snapshot = PaneSnapshot(historyAndScreen: ["$ ls", "a b"], cursorX: 2, cursorY: 1)
        #expect(SeedBuilder.build(snapshot) == bytes("\u{1b}[0m$ ls\r\na b\u{1b}[2;3H"))
    }

    @Test func testSeedForAlternateScreenSwitchesBuffers() -> Void {
        let snapshot = PaneSnapshot(historyAndScreen: ["hist"], alternateScreen: ["alt1", "alt2"], cursorX: 0, cursorY: 0)
        let seed = String(decoding: SeedBuilder.build(snapshot), as: UTF8.self)
        #expect(seed == "\u{1b}[0mhist\u{1b}[?1049h\u{1b}[Halt1\r\nalt2\u{1b}[1;1H")
    }

    @Test func testSeedRestoresMouseAndKeypadModes() -> Void {
        var snapshot = PaneSnapshot(historyAndScreen: ["x"], cursorX: 0, cursorY: 0)
        snapshot.keypadCursor = true
        snapshot.mouseAny = true
        snapshot.mouseSGR = true
        let seed = String(decoding: SeedBuilder.build(snapshot), as: UTF8.self)
        #expect(seed.hasSuffix("\u{1b}[1;1H\u{1b}[?1h\u{1b}[?1000h\u{1b}[?1003h\u{1b}[?1006h"))
        snapshot.keypadCursor = false
        snapshot.mouseAny = false
        snapshot.mouseSGR = false
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
        #expect(SeedBuilder.parseSnapshot([["hello"], ["a"], ["b"], ["c"]]) == nil)
        #expect(SeedBuilder.parseSnapshot([["---ms-snapshot--- x y"], [], [], []]) == nil)
        let valid = snapshotReplies(paneID: "%1", screen: ["$"]).compactMap { event -> [String]? in
            if case let .reply(_, lines, _) = event { return lines }
            return nil
        }
        #expect(SeedBuilder.parseSnapshot(Array(valid.prefix(3))) == nil)
        #expect(SeedBuilder.parseSnapshot(valid) != nil)
    }

    @Test func testParseSnapshotOfNormalScreenCombinesHistoryAndScreen() -> Void {
        let snapshot = SeedBuilder.parseSnapshot([
            ["---ms-snapshot--- 0 4 1 1 0 1 2 %7"], ["h1", "h2"], [""], ["s1", "s2"],
        ])
        #expect(snapshot == PaneSnapshot(
            paneID: "%7", historyAndScreen: ["h1", "h2", "s1", "s2"], alternateScreen: nil,
            cursorX: 4, cursorY: 1, keypadCursor: true, mouseAny: false, mouseSGR: true))
    }

    @Test func testParseSnapshotIgnoresHistoryBlockWhenHistoryIsEmpty() -> Void {
        let snapshot = SeedBuilder.parseSnapshot([["---ms-snapshot--- 0 0 0 0 0 0 0 %1"], ["s1"], [""], ["s1", "s2"]])
        #expect(snapshot?.historyAndScreen == ["s1", "s2"])
    }

    @Test func testParseSnapshotOfAlternateScreenUsesSavedNormalScreen() -> Void {
        let snapshot = SeedBuilder.parseSnapshot([
            ["---ms-snapshot--- 1 0 0 0 1 0 1 %2"], ["h1"], ["saved1", "saved2"], ["alt1"],
        ])
        #expect(snapshot?.historyAndScreen == ["h1", "saved1", "saved2"])
        #expect(snapshot?.alternateScreen == ["alt1"])
        #expect(snapshot?.mouseAny == true)
    }
}
