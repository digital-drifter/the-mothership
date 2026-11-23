import AppKit
import SwiftUI

/// Full-window screen shown when tmux cannot be found.
struct TmuxMissingView: View {
    let onCheckAgain: () -> Void
    private let installCommand = "brew install tmux"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("The Mothership needs tmux.")
                .font(.title2)
            Text("Install it with Homebrew, then check again.")
                .foregroundStyle(.secondary)
            HStack {
                Text(installCommand)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                }
            }
            Button("Check Again", action: onCheckAgain)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the last failed action until dismissed.
struct ActionErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        Banner(systemImage: "xmark.octagon.fill", tint: .red) {
            Text(message).textSelection(.enabled)
        } trailing: {
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
    }
}

private struct Banner<Content: View, Trailing: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) { content }
            Spacer(minLength: 0)
            trailing
        }
        .padding(10)
        .background(tint.opacity(0.12))
        .background(.bar)  // opaque, since banners float over the terminal
        .overlay(alignment: .bottom) { Divider() }
    }
}
