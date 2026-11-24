import MothershipCore
import SwiftUI

/// Settings: which of the built-in agents appear in the Agents + menu.
struct AgentSettingsView: View {
    let state: AppState
    /// Bumped when a toggle change didn't stick, so the body re-renders and the switch snaps back.
    @State private var revision = 0

    var body: some View {
        Form {
            if let message = state.actionError {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message).foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss") { state.actionError = nil }
                    }
                }
            }
            Section {
                ForEach(AgentCatalog.all) { agent in
                    Toggle(isOn: binding(for: agent)) {
                        HStack(spacing: 8) {
                            Text(agent.name)
                            Text(agent.run)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents").font(.headline)
                    Text("Choose which agents appear in the + menu.")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 6)
            }
        }
        .formStyle(.grouped)
        .id(revision)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding(for agent: KnownAgent) -> Binding<Bool> {
        Binding(
            get: { state.isAgentEnabled(agent.id) },
            set: { newValue in
                state.setAgent(agent.id, enabled: newValue)
                if state.isAgentEnabled(agent.id) != newValue { revision += 1 }
            }
        )
    }
}

/// The Settings scene's content: needs the running app state.
struct SettingsRoot: View {
    let launcher: AppLauncher

    var body: some View {
        if case .ready(let state, _) = launcher.phase {
            AgentSettingsView(state: state)
        } else {
            Text("Settings are available once Mothership has started.")
                .padding(20)
        }
    }
}
