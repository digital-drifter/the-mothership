import AppKit
import Foundation
import MothershipCore
import Observation
import SwiftTerm

/// One tmux session shown natively: owns its control client, pane stream and terminal view.
///
/// The client starts on the first `activate()` and stays attached until `close()`. If it fails or exits
/// unexpectedly the session shows as disconnected; the next `activate()` reattaches. Every seed starts with
/// a full reset, so it replaces whatever the view showed before.
@MainActor @Observable
final class TerminalSession {
    let sessionName: String
    @ObservationIgnored let view: PaneTerminalView
    /// Why the connection was lost; nil while connected or not yet started.
    private(set) var disconnectedMessage: String?

    @ObservationIgnored private let tmux: TmuxEnvironment
    @ObservationIgnored private let bridge: TerminalBridge
    @ObservationIgnored private var client: ControlClient?
    @ObservationIgnored private var stream: PaneStream?
    @ObservationIgnored private var isAttached = false
    /// Incremented per connection so callbacks from an old client are ignored.
    @ObservationIgnored private var generation = 0
    /// A window drag changes the size on every frame, and each size sent to tmux makes the program
    /// redraw its whole screen. Only the size the drag settles on is sent.
    @ObservationIgnored private lazy var resizeDebouncer = TrailingDebouncer<(cols: Int, rows: Int)>(
        delay: .milliseconds(80)
    ) { [weak self] size in
        guard let self, self.isAttached else { return }
        self.stream?.resize(cols: size.cols, rows: size.rows)
    }

    init(sessionName: String, tmux: TmuxEnvironment) {
        self.sessionName = sessionName
        self.tmux = tmux
        let view = PaneTerminalView(
            frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            options: TerminalOptions(scrollback: SeedBuilder.historyLines))
        self.view = view
        bridge = TerminalBridge()
        bridge.session = self
        view.terminalDelegate = bridge
        view.onSized = { [weak self] in self?.attachIfReady() }
    }

    /// Connects on first use (or after a disconnect) and attaches once the view has a real size.
    func activate() -> Void {
        guard client == nil else { return }
        disconnectedMessage = nil
        generation += 1
        let generation = generation
        let client = ControlClient(
            tmuxPath: tmux.tmuxPath, configPath: tmux.tmuxConfPath, socketName: tmux.socketName,
            session: sessionName)
        let stream = PaneStream(channel: client, session: sessionName)
        // Callbacks arrive in order on the client's serial queue; the main queue keeps that order.
        // Output is batched: one hop to the main thread carries everything that arrived before it ran.
        let batcher = ByteBatcher()
        stream.onBytes = { [weak self] bytes in
            guard batcher.append(bytes) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(batcher.drain(), generation: generation) }
            }
        }
        stream.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.disconnect(message, generation: generation) }
            }
        }
        client.onExit = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.disconnect("The tmux connection closed.", generation: generation)
                }
            }
        }
        do {
            try client.start()
        } catch {
            disconnectedMessage = "Could not start tmux: \(error.localizedDescription)"
            return
        }
        self.client = client
        self.stream = stream
        isAttached = false
        attachIfReady()
    }

    /// Rebuilds the view from a fresh snapshot, e.g. after respawn-pane reset the pane without any output.
    /// Not yet attached (no size or no client): the next attach seeds anyway.
    func reseed() -> Void {
        guard stream != nil, isAttached else { return }
        isAttached = false
        attachIfReady()
    }

    /// Detaches the client; the tmux session keeps running.
    func close() -> Void {
        generation += 1
        resizeDebouncer.cancel()
        client?.terminate()
        client = nil
        stream = nil
        isAttached = false
    }

    // MARK: - Terminal view events

    fileprivate func send(_ data: ArraySlice<UInt8>) -> Void {
        stream?.sendInput(Array(data))
    }

    fileprivate func sizeChanged(cols: Int, rows: Int) -> Void {
        guard isAttached, cols > 0, rows > 0 else { return }
        resizeDebouncer.submit((cols: cols, rows: rows))
    }

    // MARK: - Private

    private func attachIfReady() -> Void {
        guard let stream, !isAttached, view.frame.width > 0, view.frame.height > 0 else { return }
        let size = view.terminalDimensions
        guard size.cols > 0, size.rows > 0 else { return }
        isAttached = true
        // attach sends the current size itself.
        resizeDebouncer.cancel()
        stream.attach(cols: size.cols, rows: size.rows)
    }

    private func receive(_ bytes: [UInt8], generation: Int) -> Void {
        guard generation == self.generation else { return }
        view.feedOutput(bytes[...])
    }

    private func disconnect(_ message: String, generation: Int) -> Void {
        guard generation == self.generation else { return }
        close()
        disconnectedMessage = message
    }
}

/// Forwards SwiftTerm's delegate calls to the session (kept separate so the session stays a plain class).
@MainActor
private final class TerminalBridge: TerminalViewDelegate {
    weak var session: TerminalSession?

    func send(source: TerminalView, data: ArraySlice<UInt8>) -> Void {
        session?.send(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) -> Void {
        session?.sizeChanged(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) -> Void {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) -> Void {}
    func scrolled(source: TerminalView, position: Double) -> Void {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) -> Void {}
}

/// Sessions by name, kept while the app runs so switching items is instant.
@MainActor
final class TerminalSessionCache {
    private let tmux: TmuxEnvironment
    private var sessions: [String: TerminalSession] = [:]

    init(tmux: TmuxEnvironment) {
        self.tmux = tmux
    }

    func session(for sessionName: String) -> TerminalSession {
        if let session = sessions[sessionName] { return session }
        let session = TerminalSession(sessionName: sessionName, tmux: tmux)
        sessions[sessionName] = session
        return session
    }

    /// Re-seeds the cached sessions among `sessionNames` (panes that were respawned).
    func reseed(_ sessionNames: Set<String>) -> Void {
        for name in sessionNames { sessions[name]?.reseed() }
    }

    /// Detaches and forgets every session not in `sessionNames`.
    func prune(keeping sessionNames: Set<String>) -> Void {
        for (name, session) in sessions where !sessionNames.contains(name) {
            session.close()
            sessions[name] = nil
        }
    }
}
