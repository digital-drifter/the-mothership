import AppKit

/// Shows an AppKit menu at the mouse pointer. Lets a plain SwiftUI `Button` open a menu, because on
/// macOS a SwiftUI `Menu` draws its label image as a fixed-colour image that ignores the sidebar's tint.
@MainActor
enum PopUpMenu {
    enum Entry {
        case item(String, () -> Void)
        case divider
    }

    static func show(_ entries: [Entry]) -> Void {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case .item(let title, let action):
                let handler = MenuAction(action)
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                item.target = handler
                // The item keeps the handler alive; `target` alone is a weak reference.
                item.representedObject = handler
                menu.addItem(item)
            }
        }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

private final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() -> Void {
        action()
    }
}
