import AppKit
import MothershipCore
import SwiftTerm
import SwiftUI

/// Shows a session's cached terminal view and connects it when it appears.
struct TerminalPane: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalView {
        session.activate()
        return session.view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) -> Void {}
}

/// A terminal view that reports its first real size and takes keyboard focus when shown.
final class PaneTerminalView: TerminalView {
    /// Called whenever the frame changes to a non-empty size.
    var onSized: (() -> Void)?

    private let responseGate = TerminalResponseGate()

    /// Feeds bytes that came from the pane (seed or live output). SwiftTerm parses them synchronously,
    /// so any reply it generates for a query in them reaches `send(source:data:)` inside this call.
    func feedOutput(_ bytes: ArraySlice<UInt8>) -> Void {
        responseGate.whileFeeding { feed(byteArray: bytes) }
    }

    /// Replies the emulator generates. tmux already answered every query in the pane's output, so
    /// replies produced while that output is parsed are dropped; mouse and focus reports pass.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) -> Void {
        guard responseGate.allowsResponses else { return }
        super.send(source: source, data: data)
    }

    override func setFrameSize(_ newSize: NSSize) -> Void {
        super.setFrameSize(newSize)
        if newSize.width > 0, newSize.height > 0 { onSized?() }
    }

    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() -> Void {
        super.viewDidMoveToWindow()
        stopWaitingForKey()
        guard let window else { return }
        if window.isKeyWindow {
            focusSoon()
        } else {
            // At launch the view appears before its window is key; focus it once the window is.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stopWaitingForKey()
                    self?.focusSoon()
                }
            }
        }
    }

    /// Takes focus after SwiftUI finishes the current update, so typing goes to the terminal.
    private func focusSoon() -> Void {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    private func stopWaitingForKey() -> Void {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }
}
