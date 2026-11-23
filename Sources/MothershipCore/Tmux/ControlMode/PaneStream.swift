import Foundation

/// A pane as a byte stream: a seed that recreates the pane, then its live output, with nothing lost or repeated.
///
/// Ordering: tmux runs commands in order and emits `%output` for earlier pane changes before a command's
/// reply. So all output before the snapshot reply is already inside the snapshot and is dropped; every
/// output after it is forwarded unchanged.
///
/// A snapshot whose replies fail or don't parse is re-issued once; a second failure is reported through
/// `onFailure` and the stream stops forwarding until `attach` is called again.
public final class PaneStream: @unchecked Sendable {
    private enum State {
        /// Waiting for the marker block of snapshot attempt `attempt` (1 or 2).
        case awaitingSnapshot(attempt: Int)
        /// The marker arrived; collecting the remaining blocks of this snapshot, whatever their outcome.
        case collecting(attempt: Int, blocks: [[String]], error: String?)
        case live(paneID: String)
        case failed
    }

    private static let maxInputChunk = 1024
    private static let hexDigits: [String] = (0...255).map { String(format: "%02x", $0) }

    private let channel: ControlChannel
    private let target: String
    private let lock = NSLock()
    private var state: State = .awaitingSnapshot(attempt: 1)
    private var bytesHandler: (@Sendable ([UInt8]) -> Void)?
    private var failureHandler: (@Sendable (String) -> Void)?

    public var onBytes: (@Sendable ([UInt8]) -> Void)? {
        get { lock.withLock { bytesHandler } }
        set { lock.withLock { bytesHandler = newValue } }
    }

    /// Called with tmux's error (or a description) when the snapshot failed twice.
    public var onFailure: (@Sendable (String) -> Void)? {
        get { lock.withLock { failureHandler } }
        set { lock.withLock { failureHandler = newValue } }
    }

    /// `session` is a session name; every command targets exactly that session.
    public init(channel: ControlChannel, session: String) {
        self.channel = channel
        self.target = SessionName.target(session)
        channel.onEvent = { [weak self] event in self?.handle(event) }
    }

    public func attach(cols: Int, rows: Int) -> Void {
        lock.withLock { state = .awaitingSnapshot(attempt: 1) }
        resize(cols: cols, rows: rows)
        channel.send(SeedBuilder.snapshotCommand(target: target))
    }

    public func sendInput(_ bytes: [UInt8]) -> Void {
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.maxInputChunk, bytes.count)
            let hex = bytes[start..<end].map { Self.hexDigits[Int($0)] }.joined(separator: " ")
            channel.send("send-keys -H -t \(target) \(hex)")
            start = end
        }
    }

    public func resize(cols: Int, rows: Int) -> Void {
        channel.send("refresh-client -C \(cols)x\(rows)")
    }

    private enum Action {
        case forward([UInt8])
        case reissue
        case fail(String)
    }

    private func handle(_ event: ControlEvent) -> Void {
        var action: Action?
        let (bytes, failure) = lock.withLock { () -> ((@Sendable ([UInt8]) -> Void)?, (@Sendable (String) -> Void)?) in
            switch (event, state) {
            case let (.output(paneID, data), .live(livePane)) where paneID == livePane:
                action = .forward(data)
            case let (.reply(_, lines, isError), .awaitingSnapshot(attempt)):
                if !isError, lines == [SeedBuilder.marker] {
                    state = .collecting(attempt: attempt, blocks: [lines], error: nil)
                }
            case let (.reply(_, lines, isError), .collecting(attempt, blocks, error)):
                let blocks = blocks + [lines]
                let error = error ?? (isError ? (lines.first ?? "tmux error") : nil)
                guard blocks.count == SeedBuilder.snapshotReplyCount else {
                    state = .collecting(attempt: attempt, blocks: blocks, error: error)
                    break
                }
                if error == nil, let snapshot = SeedBuilder.parseSnapshot(blocks) {
                    state = .live(paneID: snapshot.paneID)
                    action = .forward(SeedBuilder.build(snapshot))
                } else if attempt == 1 {
                    state = .awaitingSnapshot(attempt: 2)
                    action = .reissue
                } else {
                    state = .failed
                    action = .fail(error ?? "unreadable pane snapshot")
                }
            default:
                break  // output before the snapshot or for other panes, other replies, notifications
            }
            return (bytesHandler, failureHandler)
        }
        switch action {
        case let .forward(data): bytes?(data)
        case .reissue: channel.send(SeedBuilder.snapshotCommand(target: target))
        case let .fail(message): failure?(message)
        case nil: break
        }
    }
}
