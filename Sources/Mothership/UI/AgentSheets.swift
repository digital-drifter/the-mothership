import MothershipCore
import SwiftUI

/// Starts a one-off agent from a custom command.
struct CustomAgentSheet: View {
    let state: AppState
    let projectSlug: String
    /// Called with the new agent's session name.
    let onStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var run = ""
    @State private var isWorking = false

    private var isBlank: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Agent").font(.headline)
            TextField("Name", text: $name)
            TextField("Command", text: $run)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBlank || isWorking)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func start() -> Void {
        isWorking = true
        Task {
            if let id = await state.newCustomAgent(projectSlug: projectSlug, name: name, run: run) { onStarted(id) }
            dismiss()
        }
    }
}
