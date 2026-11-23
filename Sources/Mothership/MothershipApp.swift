import AppKit
import MothershipCore
import SwiftUI

@main
struct MothershipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var launcher = AppLauncher()
    @State private var navigation = SidebarNavigation()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("The Mothership", id: "main") {
            RootView(launcher: launcher, navigation: navigation)
                .frame(minWidth: 720, minHeight: 420)
        }
        .commands { MothershipCommands(launcher: launcher, navigation: navigation) }
    }
}

private struct RootView: View {
    let launcher: AppLauncher
    let navigation: SidebarNavigation

    var body: some View {
        Group {
            switch launcher.phase {
            case .launching:
                ProgressView()
            case .tmuxMissing:
                TmuxMissingView { Task { await launcher.launch() } }
            case .ready(let state, let terminals):
                MainView(state: state, terminals: terminals, navigation: navigation)
            }
        }
        .task { await launcher.launch() }
    }
}

private struct MainView: View {
    let state: AppState
    let terminals: TerminalSessionCache
    let navigation: SidebarNavigation

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state, navigation: navigation)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            DetailView(item: selected?.item, section: selected?.section, state: state, navigation: navigation, terminals: terminals)
                // Overlays, so a banner coming or going never resizes the terminal (SIGWINCH, and a
                // reconnect must seed the view at the size tmux captured).
                .overlay(alignment: .top) {
                    if let actionError = state.actionError {
                        ActionErrorBanner(message: actionError) { state.actionError = nil }
                    }
                }
        }
    }

    private var selected: (item: SidebarItem, section: ProjectSection)? {
        for section in state.sections {
            if let item = (section.agents + section.commands + section.terminals).first(where: { $0.id == navigation.selection }) {
                return (item, section)
            }
        }
        return nil
    }
}
