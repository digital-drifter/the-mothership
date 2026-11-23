import MothershipCore
import SwiftUI

/// Projects with their Agents / Commands / Terminals, plus the per-item actions.
struct SidebarView: View {
    let state: AppState
    @Bindable var navigation: SidebarNavigation

    @State private var renaming: SidebarItem?
    @State private var renameDraft = ""
    @State private var ending: Ending?
    @State private var renamingProject: ProjectSection?
    @State private var projectRenameDraft = ""
    @State private var removing: ProjectSection?

    var body: some View {
        List(selection: $navigation.selection) {
            ForEach(state.sections) { section in
                Section(isExpanded: expansion(of: section.id)) {
                    rows(for: section)
                } header: {
                    Text(section.name).opacity(section.isOrphan ? 0.5 : 1)
                        .contextMenu { if !section.isOrphan { projectMenu(section) } }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    addProjectInteractively(state: state, navigation: navigation)
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .alert("Rename Project", isPresented: isPresented($renamingProject), presenting: renamingProject) { section in
            TextField("Name", text: $projectRenameDraft)
            Button("Rename") { state.renameProject(slug: section.id, to: projectRenameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove \u{201C}\(removing?.name ?? "")\u{201D}?", isPresented: isPresented($removing),
            presenting: removing
        ) { section in
            Button("Remove", role: .destructive) { remove(section) }
            Button("Cancel", role: .cancel) {}
        } message: { section in
            Text(removalMessage(for: section))
        }
        .alert("Rename", isPresented: isPresented($renaming), presenting: renaming) { item in
            TextField("Name", text: $renameDraft)
            Button("Rename") { rename(item) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "\(ending?.action.title ?? "") \(ending?.item.displayName ?? "")?", isPresented: isPresented($ending),
            presenting: ending
        ) { ending in
            Button(ending.action.title, role: .destructive) { perform(ending) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its process is still running and will be ended.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(for section: ProjectSection) -> some View {
        if !section.isOrphan || !section.agents.isEmpty {
            GroupHeader(title: "Agents") {
                if !section.isOrphan && !state.agents.isEmpty { newAgentMenu(section) }
            }
            ForEach(section.agents) { item in
                row(item, in: section).contextMenu { sessionMenu(item) }
            }
        }
        if !section.isOrphan || !section.commands.isEmpty {
            GroupHeader(title: "Commands") { EmptyView() }
            ForEach(section.commands) { item in
                row(item, in: section).contextMenu { commandMenu(item, in: section) }
            }
        }
        if !section.isOrphan || !section.terminals.isEmpty {
            GroupHeader(title: "Terminals") {
                if !section.isOrphan { newTerminalButton(section) }
            }
            ForEach(section.terminals) { item in
                row(item, in: section).contextMenu { sessionMenu(item) }
            }
        }
    }

    private func row(_ item: SidebarItem, in section: ProjectSection) -> some View {
        Label {
            Text(item.displayName)
        } icon: {
            StatusDot(status: item.status)
        }
        .accessibilityValue(StatusDot.accessibilityText(for: item.status))
        .opacity(item.isOrphan || section.isOrphan ? 0.5 : 1)
        .tag(Optional(item.id))
    }

    private func newAgentMenu(_ section: ProjectSection) -> some View {
        Menu {
            ForEach(state.agents, id: \.name) { template in
                Button(template.name) {
                    Task {
                        if let id = await state.newAgent(projectSlug: section.id, templateName: template.name) {
                            navigation.selection = id
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New agent")
        .accessibilityLabel("New agent")
    }

    private func newTerminalButton(_ section: ProjectSection) -> some View {
        Button {
            Task {
                if let id = await state.newTerminal(projectSlug: section.id) { navigation.selection = id }
            }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("New terminal")
        .accessibilityLabel("New terminal")
    }

    // MARK: - Context menus

    @ViewBuilder
    private func commandMenu(_ item: SidebarItem, in section: ProjectSection) -> some View {
        Button("Start") {
            Task { await state.start(commandSlug: item.commandSlug(in: section), projectSlug: section.id) }
        }
        .disabled(item.status == .running || item.isOrphan)
        Button("Stop") { Task { await state.stop(sessionName: item.id) } }
            .disabled(item.status != .running)
        Button("Restart") { Task { await state.restart(sessionName: item.id) } }
            .disabled(item.status == .notStarted)
    }

    @ViewBuilder
    private func sessionMenu(_ item: SidebarItem) -> some View {
        Button("Rename…") {
            renameDraft = item.displayName
            renaming = item
        }
        Button("Relaunch") { confirmIfRunning(Ending(item: item, action: .relaunch)) }
        Button("Close") { confirmIfRunning(Ending(item: item, action: .close)) }
    }

    @ViewBuilder
    private func projectMenu(_ section: ProjectSection) -> some View {
        Button("Rename…") {
            projectRenameDraft = section.name
            renamingProject = section
        }
        Button("Change Folder…") {
            if let path = FolderPicker.choose(title: "Change Folder", prompt: "Choose", startingAt: section.path) {
                state.changeFolder(projectSlug: section.id, to: path)
            }
        }
        Button("Remove Project…") { removing = section }
    }

    // MARK: - Actions and helpers

    private func removalMessage(for section: ProjectSection) -> String {
        let running = state.runningSessionCount(projectSlug: section.id)
        let note = "The folder on disk is not touched."
        guard running > 0 else { return note }
        return "Stops \(running) running session\(running == 1 ? "" : "s"). \(note)"
    }

    private func remove(_ section: ProjectSection) -> Void {
        let owned = Set((section.agents + section.commands + section.terminals).map(\.id))
        Task {
            await state.removeProject(slug: section.id)
            if let selection = navigation.selection, owned.contains(selection) { navigation.selection = nil }
        }
    }

    private func rename(_ item: SidebarItem) -> Void {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { await state.rename(sessionName: item.id, to: name) }
    }

    /// Ending a running process (Close, Relaunch) asks first; otherwise it happens right away.
    private func confirmIfRunning(_ request: Ending) -> Void {
        if request.item.status == .running { ending = request } else { perform(request) }
    }

    private func perform(_ request: Ending) -> Void {
        let item = request.item
        Task {
            switch request.action {
            case .close:
                await state.close(sessionName: item.id)
                if navigation.selection == item.id { navigation.selection = nil }
            case .relaunch:
                await state.relaunch(sessionName: item.id)
            }
        }
    }

    private func expansion(of projectID: String) -> Binding<Bool> {
        Binding(
            get: { navigation.isExpanded(projectID) },
            set: { navigation.setExpanded($0, for: projectID) })
    }

    private func isPresented<Value>(_ item: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// An action that ends an agent's or terminal's process, waiting for confirmation while it runs.
private struct Ending {
    enum Action {
        case close
        case relaunch

        var title: String {
            switch self {
            case .close: "Close"
            case .relaunch: "Relaunch"
            }
        }
    }

    let item: SidebarItem
    let action: Action
}

/// An "AGENTS" / "COMMANDS" / "TERMINALS" sub-header with an optional `+` control.
private struct GroupHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory
        }
        .selectionDisabled()
    }
}

/// Green filled = running, gray hollow = never started, gray filled = exited 0, red filled = exited non-zero.
private struct StatusDot: View {
    let status: ItemStatus

    var body: some View {
        Group {
            switch status {
            case .running:
                Circle().fill(.green)
            case .notStarted:
                Circle().strokeBorder(.gray, lineWidth: 1.5)
            case .exited(let code):
                Circle().fill(code == 0 ? Color.gray : Color.red)
            }
        }
        .frame(width: 8, height: 8)
    }

    /// Spoken status, since the dot itself is only a color.
    static func accessibilityText(for status: ItemStatus) -> String {
        switch status {
        case .running: "Running"
        case .notStarted: "Not started"
        case .exited(let code): "Exited (code \(code))"
        }
    }
}

extension SidebarItem {
    /// The command slug encoded in a command's session name (`ms-<project>-cmd-<slug>`).
    func commandSlug(in section: ProjectSection) -> String {
        String(id.dropFirst(SessionName.make(projectSlug: section.id, kind: .command, id: "").count))
    }
}
