import MothershipCore
import SwiftUI

/// The main pane for the selected item. `terminal` is the item's terminal view.
struct DetailView<Terminal: View>: View {
    let item: SidebarItem?
    let section: ProjectSection?
    let state: AppState
    let terminal: Terminal

    var body: some View {
        if let item, let section {
            content(item, section)
                .navigationTitle(item.displayName)
                .navigationSubtitle(section.name)
        } else {
            ContentUnavailableView("Select an item", systemImage: "sidebar.left")
        }
    }

    @ViewBuilder
    private func content(_ item: SidebarItem, _ section: ProjectSection) -> some View {
        switch item.status {
        case .notStarted where item.kind == .command:
            notStarted(item, section)
        case .exited(let code):
            VStack(spacing: 0) {
                terminalArea
                Divider()
                exitedBar(item, section, code: code)
            }
        default:
            terminalArea
        }
    }

    private var terminalArea: some View {
        terminal.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notStarted(_ item: SidebarItem, _ section: ProjectSection) -> some View {
        let slug = item.commandSlug(in: section)
        let run = state.config.projects.first { $0.slug == section.id }?
            .commands.first { $0.slug == slug }?.run
        return VStack(spacing: 12) {
            Text(item.displayName).font(.title2)
            if let run {
                Text(run)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Start") {
                Task { await state.start(commandSlug: slug, projectSlug: section.id) }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exitedBar(_ item: SidebarItem, _ section: ProjectSection, code: Int) -> some View {
        HStack {
            Text("Exited (code \(code))").foregroundStyle(.secondary)
            Spacer()
            if item.kind == .command {
                Button("Start") {
                    Task { await state.start(commandSlug: item.commandSlug(in: section), projectSlug: section.id) }
                }
                .disabled(item.isOrphan)
                Button("Restart") { Task { await state.restart(sessionName: item.id) } }
            } else {
                Button("Relaunch") { Task { await state.relaunch(sessionName: item.id) } }
                Button("Close") { Task { await state.close(sessionName: item.id) } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
