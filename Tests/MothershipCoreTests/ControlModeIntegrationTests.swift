import Foundation
import Testing
@testable import MothershipCore

private let installedTmuxPath: String? = TmuxLocator.find(environmentPath: ProcessInfo.processInfo.environment["PATH"])

/// Thread-safe collector for everything a `PaneStream` forwards.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UInt8]] = []
    private var exited = false

    var chunks: [[UInt8]] { lock.withLock { items } }
    var seed: String? { chunks.first.map { String(decoding: $0, as: UTF8.self) } }
    var text: String { String(decoding: chunks.flatMap { $0 }, as: UTF8.self) }
    var live: String { String(decoding: chunks.dropFirst().flatMap { $0 }, as: UTF8.self) }
    var didExit: Bool { lock.withLock { exited } }

    func append(_ bytes: [UInt8]) -> Void { lock.withLock { items.append(bytes) } }
    func markExited() -> Void { lock.withLock { exited = true } }
}

/// One control client plus pane stream attached to a session.
private struct Attachment {
    let client: ControlClient
    let stream: PaneStream
    let received: Received
}

/// A throwaway tmux server on its own socket; `cleanup()` terminates clients and kills it.
private final class ControlFixture: @unchecked Sendable {
    let client: TmuxClient
    let socket: String
    let tmuxPath: String
    let configPath: String
    let directory: URL
    private var attachments: [Attachment] = []

    init() throws {
        tmuxPath = installedTmuxPath!
        socket = "ms-test-\(UUID().uuidString.prefix(8))"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configPath = try TmuxConfig.install(in: directory).path
        client = TmuxClient(tmuxPath: tmuxPath, configPath: configPath, socketName: socket)
    }

    func cleanup() -> Void {
        attachments.forEach { $0.client.terminate() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-L", socket, "kill-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    func startSession(_ name: String, _ command: [String]) async throws -> Void {
        let metadata = SessionMetadata(project: "proj", kind: .command, name: "Test", template: "")
        try await client.newSession(name: name, directory: "/tmp", command: command, metadata: metadata)
    }

    /// Starts a control client with a pane stream; `attachStream: false` leaves `stream.attach` to the test.
    func attach(_ session: String, cols: Int = 80, rows: Int = 24, attachStream: Bool = true) throws -> Attachment {
        let control = ControlClient(tmuxPath: tmuxPath, configPath: configPath, socketName: socket, session: session)
        let stream = PaneStream(channel: control, target: session)
        let received = Received()
        stream.onBytes = { received.append($0) }
        control.onExit = { received.markExited() }
        let attachment = Attachment(client: control, stream: stream, received: received)
        attachments.append(attachment)
        try control.start()
        if attachStream { stream.attach(cols: cols, rows: rows) }
        return attachment
    }

    func capture(_ session: String) async -> String {
        (try? await client.run(["capture-pane", "-p", "-J", "-S", "-50000", "-t", session])) ?? ""
    }
}

/// Polls `predicate` every 20 ms until it holds or `seconds` elapse; returns the final result.
private func eventually(within seconds: Double = 5, _ predicate: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await predicate()
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// The seed's lines (without the leading SGR reset and trailing cursor/mode sequences).
private func seedLines(_ seed: String) -> [String] {
    var body = seed.hasPrefix("\u{1b}[0m") ? String(seed.dropFirst(4)) : seed
    if let cursor = body.range(of: "\u{1b}\\[[0-9]+;[0-9]+H", options: [.regularExpression, .backwards]) {
        body = String(body[..<cursor.lowerBound])
    }
    return body.components(separatedBy: "\r\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

/// The text a terminal holds before the cursor after drawing a normal-screen seed of `rows` rows.
private func seedTextBeforeCursor(_ seed: String, rows: Int) -> String? {
    var body = seed.hasPrefix("\u{1b}[0m") ? String(seed.dropFirst(4)) : seed
    guard let cursor = body.range(of: "\u{1b}\\[[0-9]+;[0-9]+H", options: [.regularExpression, .backwards]) else { return nil }
    let position = body[cursor].dropFirst(2).dropLast().split(separator: ";").compactMap { Int($0) }
    body = String(body[..<cursor.lowerBound])
    guard position.count == 2 else { return nil }
    let lines = body.components(separatedBy: "\r\n")
    let row = lines.count - rows + position[0] - 1
    guard row >= 0, row < lines.count else { return nil }
    return (lines[..<row] + [String(lines[row].prefix(position[1] - 1))]).joined(separator: "\n")
}

@Suite(.enabled(if: installedTmuxPath != nil))
struct ControlModeIntegrationTests {
    @Test func testEchoRoundTrip() async throws -> Void {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        try await fixture.startSession("ms-proj-term-echo01", ["/bin/sh"])
        let attachment = try fixture.attach("ms-proj-term-echo01")
        #expect(await eventually { attachment.received.seed != nil })
        attachment.stream.sendInput(Array("echo hi-there\r".utf8))
        // Once for the echoed keystrokes, once for the command's output.
        #expect(await eventually(within: 3) { occurrences(of: "hi-there", in: attachment.received.live) >= 2 })
    }

    @Test func testCommandAwaitsItsOwnReplyNotTheAttachBlock() async throws -> Void {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        try await fixture.startSession("ms-proj-cmd-reply", ["/bin/sh", "-c", "sleep 30"])
        let attachment = try fixture.attach("ms-proj-cmd-reply")
        let first = try await attachment.client.command("display-message -p hello-one")
        let second = try await attachment.client.command("display-message -p hello-two")
        #expect(first == ["hello-one"])
        #expect(second == ["hello-two"])
        await #expect(throws: ControlClientError.self) { try await attachment.client.command("no-such-command") }
        #expect(try await attachment.client.command("display-message -p after-error") == ["after-error"])
    }

    @Test func testExitFailsPendingCommandsAndCallsOnExit() async throws -> Void {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        try await fixture.startSession("ms-proj-cmd-exit", ["/bin/sh", "-c", "sleep 30"])
        let attachment = try fixture.attach("ms-proj-cmd-exit")
        #expect(await eventually { attachment.received.seed != nil })
        attachment.client.terminate()
        #expect(await eventually { attachment.received.didExit })
        await #expect(throws: ControlClientError.self) { try await attachment.client.command("display-message -p x") }
    }

    @Test func testReattachSeedsHistory() async throws -> Void {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let session = "ms-proj-term-hist01"
        try await fixture.startSession(session, ["/bin/sh"])
        let first = try fixture.attach(session)
        #expect(await eventually { first.received.seed != nil })
        first.stream.sendInput(Array("i=1; while [ $i -le 200 ]; do echo line-$i; i=$((i+1)); done\r".utf8))
        #expect(await eventually { first.received.live.contains("line-200\r\n") })
        first.client.terminate()
        #expect(await eventually { first.received.didExit })

        let second = try fixture.attach(session)
        #expect(await eventually { second.received.seed != nil })
        try await Task.sleep(for: .milliseconds(300))
        let lines = seedLines(second.received.seed ?? "")
        #expect(lines.filter { $0 == "line-1" }.count == 1)
        #expect(lines.filter { $0 == "line-200" }.count == 1)
        #expect(occurrences(of: "line-200", in: second.received.text) == 1)
    }

    @Test func testReattachDuringAlternateScreen() async throws -> Void {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let session = "ms-proj-cmd-alt"
        // NORMAL-HISTORY scrolls into history; fill-60 stays on the saved normal screen.
        let script = "echo NORMAL-HISTORY; i=1; while [ $i -le 60 ]; do echo fill-$i; i=$((i+1)); done; "
            + "printf '\\033[?1049h\\033[HALT-SCREEN'; sleep 30"
        try await fixture.startSession(session, ["/bin/sh", "-c", script])
        #expect(await eventually { await fixture.capture(session).contains("ALT-SCREEN") })
        let attachment = try fixture.attach(session)
        #expect(await eventually { attachment.received.seed != nil })
        let seed = attachment.received.seed ?? ""
        let history = seed.range(of: "NORMAL-HISTORY")
        let lastFill = seed.range(of: "fill-60")
        let switchToAlt = seed.range(of: "\u{1b}[?1049h")
        let alt = seed.range(of: "ALT-SCREEN")
        #expect(history != nil && lastFill != nil && switchToAlt != nil && alt != nil)
        if let history, let lastFill, let switchToAlt, let alt {
            #expect(history.upperBound <= lastFill.lowerBound)
            #expect(lastFill.upperBound <= switchToAlt.lowerBound)
            #expect(switchToAlt.upperBound <= alt.lowerBound)
        }
        #expect(occurrences(of: "NORMAL-HISTORY", in: seed) == 1)
        #expect(occurrences(of: "fill-60", in: seed) == 1)
        #expect(occurrences(of: "ALT-SCREEN", in: seed) == 1)
    }

    @Test func testReattachToDeadPaneShowsLastOutput() async throws -> Void {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let session = "ms-proj-cmd-dead"
        try await fixture.startSession(session, ["/bin/sh", "-c", "echo LAST-WORDS; exit 0"])
        #expect(await eventually {
            (try? await fixture.client.listPanes().first { $0.sessionName == session }?.isDead) == true
        })
        let attachment = try fixture.attach(session)
        #expect(await eventually { attachment.received.seed != nil })
        #expect(attachment.received.seed?.contains("LAST-WORDS") == true)
    }

    @Test func testDetachLeavesSessionRunning() async throws -> Void {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let session = "ms-proj-cmd-detach"
        try await fixture.startSession(session, ["/bin/sh", "-c", "sleep 30"])
        let attachment = try fixture.attach(session)
        #expect(await eventually { attachment.received.seed != nil })
        attachment.client.terminate()
        #expect(await eventually { attachment.received.didExit })
        let pane = try await fixture.client.listPanes().first { $0.sessionName == session }
        #expect(pane != nil)
        #expect(pane?.isDead == false)
    }

    @Test func testSeedAndLiveOutputAreContiguousWhileThePaneIsPrinting() async throws -> Void {
        let fixture = try ControlFixture()
        defer { fixture.cleanup() }
        let session = "ms-proj-cmd-flood"
        // Fast but endless, so output is in flight both while the snapshot is taken and after it.
        let script = "i=0; while :; do echo n-$i; i=$((i+1)); [ $((i % 50)) -eq 0 ] && sleep 0.01; done"
        try await fixture.startSession(session, ["/bin/sh", "-c", script])
        #expect(await eventually { await fixture.capture(session).contains("n-2000") })
        // Let live %output pile up on the client before asking for the snapshot, so the stream must drop it.
        let attachment = try fixture.attach(session, attachStream: false)
        try await Task.sleep(for: .milliseconds(300))
        attachment.stream.attach(cols: 80, rows: 24)
        #expect(await eventually { attachment.received.seed != nil })
        #expect(await eventually { attachment.received.live.utf8.contains(0x0A) })
        try await Task.sleep(for: .milliseconds(300))

        let seedText = seedTextBeforeCursor(attachment.received.seed ?? "", rows: 24)
        #expect(seedText != nil)
        let live = attachment.received.live.replacingOccurrences(of: "\r\n", with: "\n")
        let all = (seedText ?? "") + live
        var numbers = all.split(separator: "\n").compactMap { line -> Int? in
            line.hasPrefix("n-") ? Int(line.dropFirst(2)) : nil
        }
        // The last line may still be mid-write when the test samples it.
        if !all.hasSuffix("\n") { numbers.removeLast() }
        let seedCount = (seedText ?? "").split(separator: "\n").filter { $0.hasPrefix("n-") }.count
        #expect(seedCount > 24)
        #expect(numbers.count > seedCount)
        let gaps = zip(numbers, numbers.dropFirst()).filter { $1 != $0 + 1 }
        #expect(gaps.isEmpty, "non-contiguous at \(gaps.prefix(5))")
    }
}
