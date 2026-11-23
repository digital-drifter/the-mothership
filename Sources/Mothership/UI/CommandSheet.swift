import MothershipCore
import SwiftUI

/// Adds a command to a project, or edits an existing one (prefilled).
struct CommandSheet: View {
    /// What the sheet edits. Nil means a new command.
    struct Editing {
        let slug: String
        let name: String
        let run: String
        let autostart: Bool
        let isRunning: Bool
    }

    let state: AppState
    let projectSlug: String
    let editing: Editing?
    /// Called with the new command's session name after a successful add.
    let onAdded: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var run: String
    @State private var autostart: Bool
    @State private var problem: String?

    init(state: AppState, projectSlug: String, editing: Editing?, onAdded: @escaping (String) -> Void) {
        self.state = state
        self.projectSlug = projectSlug
        self.editing = editing
        self.onAdded = onAdded
        _name = State(initialValue: editing?.name ?? "")
        _run = State(initialValue: editing?.run ?? "")
        _autostart = State(initialValue: editing?.autostart ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "New Command" : "Edit Command").font(.headline)
            TextField("Name", text: $name)
            TextField("Command", text: $run, prompt: Text("npm run dev"))
            Toggle("Start automatically when Mothership opens", isOn: $autostart)
            if editing?.isRunning == true {
                Text("Changes to the command take effect on the next Start or Restart.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() -> Void {
        if let message = state.validateCommand(projectSlug: projectSlug, name: name, run: run, editing: editing?.slug) {
            problem = message
            return
        }
        Task {
            if let editing {
                await state.editCommand(
                    projectSlug: projectSlug, commandSlug: editing.slug, name: name, run: run, autostart: autostart)
            } else if let id = await state.addCommand(projectSlug: projectSlug, name: name, run: run, autostart: autostart) {
                onAdded(id)
            }
            dismiss()
        }
    }
}
