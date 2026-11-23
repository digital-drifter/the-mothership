import AppKit
import Observation
import MothershipCore
import SwiftUI

/// True while Stop All is running, so it cannot be repeated and a plain quit cannot cut it short.
@MainActor @Observable
final class StopAllGate {
    static let shared = StopAllGate()
    var isStopping = false
}

/// Holds ⌘Q back while Stop All is in flight; Stop All quits by itself when it finishes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        StopAllGate.shared.isStopping ? .terminateCancel : .terminateNow
    }
}

/// App-wide menu items: New Terminal, project shortcuts and Stop All and Quit.
struct MothershipCommands: Commands {
    let launcher: AppLauncher
    let navigation: SidebarNavigation

    private var state: AppState? {
        if case .ready(let state, _) = launcher.phase { return state }
        return nil
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {}
        CommandGroup(after: .newItem) {
            Button("Add Project…") { addProject() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(state == nil)
            Button("New Terminal") { newTerminal() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(terminalTarget == nil)
        }
        CommandMenu("Projects") {
            let sections = state?.sections ?? []
            ForEach(Array(sections.prefix(9).enumerated()), id: \.element.id) { index, section in
                Button(section.name) { navigation.selectProject(at: index, in: sections) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        CommandGroup(after: .appTermination) {
            Button("Stop All and Quit") { confirmStopAll() }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .disabled(state == nil || StopAllGate.shared.isStopping)
        }
    }

    private var terminalTarget: ProjectSection? {
        state.flatMap { navigation.terminalTarget(in: $0.sections) }
    }

    private func addProject() -> Void {
        guard let state else { return }
        addProjectInteractively(state: state, navigation: navigation)
    }

    private func newTerminal() -> Void {
        guard let state, let target = terminalTarget else { return }
        navigation.setExpanded(true, for: target.id)
        Task {
            if let id = await state.newTerminal(projectSlug: target.id) { navigation.selection = id }
        }
    }

    private func confirmStopAll() -> Void {
        guard let state else { return }
        let alert = NSAlert()
        alert.messageText = "Stop all sessions and quit?"
        alert.informativeText = "Every running agent, command and terminal will be ended."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop All and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        StopAllGate.shared.isStopping = true
        Task {
            let stopped = await state.stopAll()
            StopAllGate.shared.isStopping = false
            // On failure stay open: the error banner shows and the sessions are still running.
            if stopped { NSApp.terminate(nil) }
        }
    }
}
