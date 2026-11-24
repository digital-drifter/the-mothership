import Foundation

/// Decides whether a reply the terminal emulator generated may go to the pane.
///
/// tmux is the real terminal for every pane: it already answers queries such as DSR (`ESC[6n`) and
/// DA (`ESC[c`) before the bytes reach the app as `%output`. When the emulator parses those bytes it
/// answers them a second time, and forwarding that answer would type it into the program. Replies
/// produced while fed output is being parsed are therefore dropped; replies produced at any other
/// time (mouse reports, focus events) come from the user and pass.
///
/// The gate is per thread. The emulator produces a reply synchronously on the thread that is parsing,
/// so "produced while parsing" means "produced on a thread that is inside `whileFeeding`". Output is
/// parsed on a background thread; a report the user causes on the main thread meanwhile still passes.
public final class TerminalResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    /// Feed nesting depth per thread, keyed by the thread's Mach port.
    private var feedDepths: [mach_port_t: Int] = [:]

    public init() {}

    /// Runs `body` (which feeds pane output to the emulator) with this thread's replies suppressed.
    public func whileFeeding<T>(_ body: () throws -> T) rethrows -> T {
        let thread = pthread_mach_thread_np(pthread_self())
        lock.withLock { feedDepths[thread, default: 0] += 1 }
        defer {
            lock.withLock {
                let depth = (feedDepths[thread] ?? 1) - 1
                feedDepths[thread] = depth > 0 ? depth : nil
            }
        }
        return try body()
    }

    /// False on a thread that is feeding output, true everywhere else.
    public var allowsResponses: Bool {
        let thread = pthread_mach_thread_np(pthread_self())
        return lock.withLock { feedDepths[thread] == nil }
    }
}
