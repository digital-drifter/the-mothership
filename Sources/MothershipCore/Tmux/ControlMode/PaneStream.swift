import Foundation

/// A pane as a byte stream: a seed that recreates the pane, then its live output, with nothing lost or repeated.
///
/// Ordering: tmux runs commands in order and emits `%output` for earlier pane changes before a command's
/// reply. So all output before the snapshot reply is already inside the snapshot and is dropped; every
/// output after it is forwarded unchanged.
public final class PaneStream: @unchecked Sendable {
    private enum State {
        case awaitingSnapshot
        case collecting([[String]])
        case live(paneID: String)
    }

    private static let maxInputChunk = 1024
    private static let hexDigits: [String] = (0...255).map { String(format: "%02x", $0) }

    private let channel: ControlChannel
    private let target: String
    private let lock = NSLock()
    private var state: State = .awaitingSnapshot
    private var bytesHandler: (@Sendable ([UInt8]) -> Void)?

    public var onBytes: (@Sendable ([UInt8]) -> Void)? {
        get { lock.withLock { bytesHandler } }
        set { lock.withLock { bytesHandler = newValue } }
    }

    public init(channel: ControlChannel, target: String) {
        self.channel = channel
        self.target = target
        channel.onEvent = { [weak self] event in self?.handle(event) }
    }

    public func attach(cols: Int, rows: Int) -> Void {
        lock.withLock { state = .awaitingSnapshot }
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

    private func handle(_ event: ControlEvent) -> Void {
        var forward: [UInt8]?
        let handler: (@Sendable ([UInt8]) -> Void)? = lock.withLock {
            switch (event, state) {
            case let (.output(paneID, data), .live(livePane)) where paneID == livePane:
                forward = data
            case let (.reply(_, lines, isError), .awaitingSnapshot):
                if !isError, lines.count == 1, lines[0].hasPrefix(SeedBuilder.marker + " ") {
                    state = .collecting([lines])
                }
            case let (.reply(_, lines, isError), .collecting(blocks)):
                if isError {
                    state = .awaitingSnapshot
                } else if blocks.count + 1 < SeedBuilder.snapshotReplyCount {
                    state = .collecting(blocks + [lines])
                } else if let snapshot = SeedBuilder.parseSnapshot(blocks + [lines]) {
                    state = .live(paneID: snapshot.paneID)
                    forward = SeedBuilder.build(snapshot)
                } else {
                    state = .awaitingSnapshot
                }
            default:
                break  // output before the snapshot or for other panes, other replies, notifications
            }
            return bytesHandler
        }
        if let forward { handler?(forward) }
    }
}
