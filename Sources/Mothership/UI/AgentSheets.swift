import MothershipCore
import SwiftUI

/// Starts a one-off agent from a custom command, optionally saving it to the agent list.
struct CustomAgentSheet: View {
    let state: AppState
    let projectSlug: String
    /// Called with the new agent's session name.
    let onStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var run = ""
    @State private var saveToList = false
    @State private var problem: String?
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
            Toggle("Save to list", isOn: $saveToList)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
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
        if saveToList {
            if let message = state.validateAgentTemplate(name: name, run: run) {
                problem = message
                return
            }
            state.addAgentTemplate(name: name, run: run)
        }
        isWorking = true
        Task {
            if let id = await state.newCustomAgent(projectSlug: projectSlug, name: name, run: run) { onStarted(id) }
            dismiss()
        }
    }
}

/// Lists the saved agents with a way to remove each.
struct ManageAgentsSheet: View {
    let state: AppState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Agents").font(.headline)
            if state.agents.isEmpty {
                Text("No saved agents. Use Custom… to add one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(state.agents, id: \.name) { agent in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(agent.name)
                                Text(agent.run).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                state.removeAgentTemplate(name: agent.name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(agent.name)")
                            .accessibilityLabel("Remove \(agent.name)")
                        }
                    }
                }
                .frame(minHeight: 120)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
