import MothershipCore
import SwiftUI

/// Adds a command to a project, or edits an existing one (prefilled).
struct CommandSheet: View {
    /// What the sheet edits. Nil means a new command.
    struct Editing {
        let slug: String
        let name: String
        let run: String
        /// The stored directory, or "" for the project folder.
        let directory: String
        let autostart: Bool
        let isRunning: Bool
    }

    let state: AppState
    let projectSlug: String
    /// The project's folder, which relative directories resolve against.
    let projectPath: String
    let editing: Editing?
    /// Called with the new command's session name after a successful add.
    let onAdded: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var run: String
    @State private var directory: String
    @State private var autostart: Bool
    @State private var problem: String?
    @State private var isWorking = false

    init(state: AppState, projectSlug: String, projectPath: String, editing: Editing?, onAdded: @escaping (String) -> Void) {
        self.state = state
        self.projectSlug = projectSlug
        self.projectPath = projectPath
        self.editing = editing
        self.onAdded = onAdded
        _name = State(initialValue: editing?.name ?? "")
        _run = State(initialValue: editing?.run ?? "")
        _directory = State(initialValue: editing?.directory ?? "")
        _autostart = State(initialValue: editing?.autostart ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "New Command" : "Edit Command").font(.headline)
            TextField("Name", text: $name)
            TextField("Command", text: $run, prompt: Text("npm run dev"))
            HStack {
                TextField("Working directory", text: $directory, prompt: Text("Project folder"))
                    .help("Relative to the project folder, or an absolute path. Leave blank for the project folder.")
                Button("Choose\u{2026}") { chooseDirectory() }
            }
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
                    .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func chooseDirectory() -> Void {
        let current = ProjectConfig(
            slug: projectSlug, name: "", path: projectPath,
            commands: []
        ).workingDirectory(for: CommandConfig(slug: "", name: "", run: "", autostart: false, directory: directory))
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: current, isDirectory: &isFolder) && isFolder.boolValue
        guard let picked = FolderPicker.choose(title: "Working Directory", prompt: "Choose", startingAt: exists ? current : projectPath)
        else { return }
        directory = RelativePath.storedDirectory(picked: picked, projectPath: projectPath)
    }

    private func save() -> Void {
        if let message = state.validateCommand(projectSlug: projectSlug, name: name, run: run, directory: directory, editing: editing?.slug) {
            problem = message
            return
        }
        isWorking = true
        Task {
            if let editing {
                await state.editCommand(
                    projectSlug: projectSlug, commandSlug: editing.slug, name: name, run: run, directory: directory, autostart: autostart)
            } else if let id = await state.addCommand(projectSlug: projectSlug, name: name, run: run, directory: directory, autostart: autostart) {
                onAdded(id)
            }
            dismiss()
        }
    }
}
