import Foundation
import MothershipCore
import Observation

/// Sidebar selection and which project sections are collapsed. Shared by the sidebar and the menu commands.
@MainActor @Observable
final class SidebarNavigation {
    private static let selectionKey = "selectedItemID"

    var selection: String? {
        didSet { defaults.set(selection, forKey: Self.selectionKey) }
    }
    var collapsed: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.selectionKey)
    }

    func isExpanded(_ projectID: String) -> Bool {
        !collapsed.contains(projectID)
    }

    func setExpanded(_ expanded: Bool, for projectID: String) -> Void {
        if expanded { collapsed.remove(projectID) } else { collapsed.insert(projectID) }
    }

    /// Expands the Nth section (0-based) and selects its first item: agents, then commands, then terminals.
    func selectProject(at index: Int, in sections: [ProjectSection]) -> Void {
        guard sections.indices.contains(index) else { return }
        let section = sections[index]
        setExpanded(true, for: section.id)
        if let first = (section.agents + section.commands + section.terminals).first {
            selection = first.id
        }
    }

    /// Expands a project and drops a selection that belongs to another project's items. Section headers are
    /// not list rows, so a project cannot be selected itself; revealing it is the closest thing.
    func reveal(projectSlug: String, in sections: [ProjectSection]) -> Void {
        setExpanded(true, for: projectSlug)
        let owner = sections.first { section in
            (section.agents + section.commands + section.terminals).contains { $0.id == selection }
        }
        if let owner, owner.id != projectSlug { selection = nil }
    }

    /// The project new terminals go to: the selected item's project, else the first config project.
    func terminalTarget(in sections: [ProjectSection]) -> ProjectSection? {
        let selected = sections.first { section in
            (section.agents + section.commands + section.terminals).contains { $0.id == selection }
        }
        let target = selected ?? sections.first { !$0.isOrphan }
        return target.flatMap { $0.isOrphan ? nil : $0 }
    }
}
