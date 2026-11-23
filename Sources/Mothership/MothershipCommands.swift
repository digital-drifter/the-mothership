import AppKit
import MothershipCore
import SwiftUI

/// App-wide menu items: Open Config, New Terminal, project shortcuts and Stop All and Quit.
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
            Button("New Terminal") { newTerminal() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(terminalTarget == nil)
            Button("Open Config") { NSWorkspace.shared.open(launcher.options.configURL) }
                .keyboardShortcut(",", modifiers: .command)
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
                .disabled(state == nil)
        }
    }

    private var terminalTarget: ProjectSection? {
        state.flatMap { navigation.terminalTarget(in: $0.sections) }
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
        Task {
            await state.stopAll()
            NSApp.terminate(nil)
        }
    }
}
