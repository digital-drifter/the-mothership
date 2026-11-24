import Foundation

/// Collects bytes arriving on one thread so another can take them in batches, in order.
///
/// A flooding pane emits thousands of small outputs a second. Handing each one to the main thread on
/// its own costs a hop and a parser call apiece; with a batcher the producer schedules one drain per
/// batch and everything that arrives before that drain runs rides along.
public final class ByteBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var drainScheduled = false

    public init() {}

    /// Adds bytes to the current batch. Returns true when the caller must schedule a `drain()`;
    /// false when one is already on its way and will pick these bytes up.
    public func append(_ bytes: [UInt8]) -> Bool {
        lock.withLock {
            buffer.append(contentsOf: bytes)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
    }

    /// Takes the whole batch and starts a new one.
    public func drain() -> [UInt8] {
        lock.withLock {
            drainScheduled = false
            let batch = buffer
            buffer = []
            return batch
        }
    }
}
