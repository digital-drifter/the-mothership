import Foundation

/// Delivers only the last value of a burst, once no new value has arrived for `delay`.
@MainActor
public final class TrailingDebouncer<Value: Sendable> {
    private let delay: Duration
    private let action: @MainActor (Value) -> Void
    private var pending: Task<Void, Never>?

    public init(delay: Duration, action: @escaping @MainActor (Value) -> Void) {
        self.delay = delay
        self.action = action
    }

    public func submit(_ value: Value) -> Void {
        pending?.cancel()
        pending = Task { [delay, action] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action(value)
        }
    }

    /// Drops a value that has not been delivered yet.
    public func cancel() -> Void {
        pending?.cancel()
        pending = nil
    }
}
