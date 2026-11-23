import AppKit
import SwiftUI

@main
struct MothershipApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("The Mothership") {
            Text("The Mothership")
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
