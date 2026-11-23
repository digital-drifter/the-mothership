import AppKit
import MothershipCore
import SwiftUI

@main
struct MothershipApp: App {
    @State private var launcher = AppLauncher()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("The Mothership", id: "main") {
            RootView(launcher: launcher)
                .frame(minWidth: 720, minHeight: 420)
        }
    }
}

private struct RootView: View {
    let launcher: AppLauncher

    var body: some View {
        Group {
            switch launcher.phase {
            case .launching:
                ProgressView()
            case .tmuxMissing:
                TmuxMissingView { Task { await launcher.launch() } }
            case .ready(let state):
                MainView(state: state, configURL: launcher.options.configURL)
            }
        }
        .task { await launcher.launch() }
    }
}

private struct MainView: View {
    let state: AppState
    let configURL: URL
    @AppStorage("selectedItemID") private var selectedItemID: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state, selection: $selectedItemID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if let configError = state.configError {
                    ConfigErrorBanner(message: configError, configURL: configURL)
                }
                if let actionError = state.actionError {
                    ActionErrorBanner(message: actionError) { state.actionError = nil }
                }
                DetailView(
                    item: selected?.item, section: selected?.section, state: state,
                    terminal: Text(selected?.item.id ?? ""))
            }
        }
    }

    private var selected: (item: SidebarItem, section: ProjectSection)? {
        for section in state.sections {
            if let item = (section.agents + section.commands + section.terminals).first(where: { $0.id == selectedItemID }) {
                return (item, section)
            }
        }
        return nil
    }
}
