import Foundation

/// Decides whether a reply the terminal emulator generated may go to the pane.
///
/// tmux is the real terminal for every pane: it already answers queries such as DSR (`ESC[6n`) and
/// DA (`ESC[c`) before the bytes reach the app as `%output`. When the emulator parses those bytes it
/// answers them a second time, and forwarding that answer would type it into the program. Replies
/// produced while fed output is being parsed are therefore dropped; replies produced at any other
/// time (mouse reports, focus events) come from the user and pass.
public final class TerminalResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var feedDepth = 0

    public init() {}

    /// Runs `body` (which feeds pane output to the emulator) with replies suppressed.
    public func whileFeeding<T>(_ body: () throws -> T) rethrows -> T {
        lock.withLock { feedDepth += 1 }
        defer { lock.withLock { feedDepth -= 1 } }
        return try body()
    }

    /// False while output is being fed, true otherwise.
    public var allowsResponses: Bool {
        lock.withLock { feedDepth == 0 }
    }
}
