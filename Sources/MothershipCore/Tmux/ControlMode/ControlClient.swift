import Foundation

/// A tmux control-mode connection.
///
/// Every line written must hold exactly one tmux command: tmux answers each command with its own reply
/// block, and replies are matched to lines in FIFO order.
public protocol ControlChannel: AnyObject, Sendable {
    /// All events including replies, in wire order, on one serial queue.
    var onEvent: (@Sendable (ControlEvent) -> Void)? { get set }
    /// Fire-and-forget; the reply still arrives via `onEvent`. Several commands may be passed as separate
    /// lines; they are written in a single write so tmux runs them back to back.
    func send(_ commandLine: String) -> Void
    /// Sends one command and awaits its own reply.
    func command(_ commandLine: String) async throws -> [String]
}

public enum ControlClientError: Error, Equatable {
    case notRunning
    case invalidCommand(String)
    case commandFailed([String])
    case exited
}

/// Runs `tmux -C attach-session` over plain pipes (tmux 3.8 accepts control mode without a tty).
public final class ControlClient: ControlChannel, @unchecked Sendable {
    private enum Pending {
        case ignored
        case awaiting(CheckedContinuation<[String], any Error>)
    }

    private let tmuxPath: String
    private let configPath: String
    private let socketName: String
    private let session: String
    private let queue = DispatchQueue(label: "mothership.control-client")
    private let queueKey = DispatchSpecificKey<Void>()

    // All state below is only touched on `queue`.
    private var parser = ControlModeParser()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Pending] = []
    private var sawAttachReply = false
    private var running = false
    private var eventHandler: (@Sendable (ControlEvent) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?

    public var onEvent: (@Sendable (ControlEvent) -> Void)? {
        get { onQueue { eventHandler } }
        set { onQueue { eventHandler = newValue } }
    }

    public var onExit: (@Sendable () -> Void)? {
        get { onQueue { exitHandler } }
        set { onQueue { exitHandler = newValue } }
    }

    public init(tmuxPath: String, configPath: String, socketName: String = "mothership", session: String) {
        self.tmuxPath = tmuxPath
        self.configPath = configPath
        self.socketName = socketName
        self.session = session
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        try? input?.close()
    }

    public func start() throws -> Void {
        try onQueue {
            guard process == nil else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["-L", socketName, "-f", configPath, "-C", "attach-session", "-t", SessionName.target(session)]
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            // Writing after tmux exits must fail with EPIPE, not kill the app with SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                guard let self else { return }
                queue.async { data.isEmpty ? self.finish() : self.receive(data) }
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                throw error
            }
            self.process = process
            input = stdin.fileHandleForWriting
            running = true
        }
    }

    /// Detaches this client; never kills the session. `onExit` follows once tmux has gone.
    public func terminate() -> Void {
        onQueue {
            guard running, input != nil else { return }
            if write(["detach-client"]) { pending.append(.ignored) }
            try? input?.close()
            input = nil
        }
    }

    public func send(_ commandLine: String) -> Void {
        let lines = Self.commandLines(commandLine)
        guard !lines.isEmpty else { return }
        queue.async { [self] in
            if write(lines) { pending += lines.map { _ in .ignored } }
        }
    }

    public func command(_ commandLine: String) async throws -> [String] {
        let lines = Self.commandLines(commandLine)
        guard lines.count == 1 else { throw ControlClientError.invalidCommand(commandLine) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if write(lines) {
                    pending.append(.awaiting(continuation))
                } else {
                    continuation.resume(throwing: ControlClientError.notRunning)
                }
            }
        }
    }

    // MARK: - On `queue`

    private func write(_ lines: [String]) -> Bool {
        guard running, let input else { return false }
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        do {
            try input.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func receive(_ data: Data) -> Void {
        for event in parser.feed([UInt8](data)) {
            eventHandler?(event)
            guard case let .reply(_, lines, isError) = event else { continue }
            // tmux answers the attach itself with an unsolicited block before any command reply.
            guard sawAttachReply else {
                sawAttachReply = true
                continue
            }
            guard !pending.isEmpty else { continue }
            if case let .awaiting(continuation) = pending.removeFirst() {
                if isError {
                    continuation.resume(throwing: ControlClientError.commandFailed(lines))
                } else {
                    continuation.resume(returning: lines)
                }
            }
        }
    }

    private func finish() -> Void {
        guard running else { return }
        running = false
        try? input?.close()
        input = nil
        let waiting = pending
        pending = []
        for case let .awaiting(continuation) in waiting {
            continuation.resume(throwing: ControlClientError.exited)
        }
        exitHandler?()
    }

    // MARK: - Helpers

    /// Runs `body` on `queue`, directly when already on it (e.g. from inside `onEvent`).
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    /// Splits into non-blank lines; tmux treats an empty control-mode line as a request to detach.
    static func commandLines(_ text: String) -> [String] {
        // Fast path: one ASCII line (every `send-keys -H`, however large) needs no splitting.
        var isSingleASCIILine = true
        var hasContent = false
        for byte in text.utf8 {
            if byte >= 0x80 || (byte >= 0x0A && byte <= 0x0D) {
                isSingleASCIILine = false
                break
            }
            if byte != 0x20 && byte != 0x09 { hasContent = true }
        }
        if isSingleASCIILine { return hasContent ? [text] : [] }
        return text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
