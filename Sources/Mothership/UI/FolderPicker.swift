import AppKit
import MothershipCore

/// A modal folder chooser.
@MainActor
enum FolderPicker {
    /// The chosen folder's path, or nil when cancelled.
    static func choose(title: String, prompt: String, startingAt: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let startingAt { panel.directoryURL = URL(fileURLWithPath: startingAt, isDirectory: true) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}

/// Add Project: pick a folder, add it, and reveal the project. Shared by the sidebar button and the File menu.
@MainActor
func addProjectInteractively(state: AppState, navigation: SidebarNavigation) -> Void {
    guard let path = FolderPicker.choose(title: "Add Project", prompt: "Add", startingAt: nil),
        let slug = state.addProject(path: path)
    else { return }
    navigation.reveal(projectSlug: slug, in: state.sections)
}
