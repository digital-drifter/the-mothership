import Foundation
import Testing
import MothershipCore
@testable import Mothership

@MainActor
struct SidebarNavigationTests {
    private func makeNavigation() -> SidebarNavigation {
        SidebarNavigation(defaults: UserDefaults(suiteName: "SidebarNavigationTests-\(UUID().uuidString)")!)
    }

    @Test func testRevealExpandsACollapsedProject() -> Void {
        let navigation = makeNavigation()
        navigation.setExpanded(false, for: "es")
        #expect(!navigation.isExpanded("es"))

        navigation.reveal(projectSlug: "es", in: [])

        #expect(navigation.isExpanded("es"))
    }

    @Test func testRevealClearsASelectionInAnotherProject() -> Void {
        let navigation = makeNavigation()
        let item = SidebarItem(id: "ms-a-term-1", kind: .terminal, displayName: "t", status: .running, isOrphan: false)
        let a = ProjectSection(id: "a", name: "A", path: "/a", isOrphan: false, agents: [], commands: [], terminals: [item])
        let b = ProjectSection(id: "b", name: "B", path: "/b", isOrphan: false, agents: [], commands: [], terminals: [])
        navigation.selection = item.id

        navigation.reveal(projectSlug: "b", in: [a, b])
        #expect(navigation.selection == nil)

        navigation.selection = item.id
        navigation.reveal(projectSlug: "a", in: [a, b])
        #expect(navigation.selection == item.id)
    }
}
