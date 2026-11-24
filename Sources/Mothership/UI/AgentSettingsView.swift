import MothershipCore
import SwiftUI

/// Settings: which of the built-in agents appear in the Agents + menu.
struct AgentSettingsView: View {
    let state: AppState

    var body: some View {
        Form {
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
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding(for agent: KnownAgent) -> Binding<Bool> {
        Binding(
            get: { state.isAgentEnabled(agent.id) },
            set: { state.setAgent(agent.id, enabled: $0) }
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
