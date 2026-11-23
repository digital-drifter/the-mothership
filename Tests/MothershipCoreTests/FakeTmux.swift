import Foundation
@testable import MothershipCore

actor FakeTmux: TmuxCommanding {
    private(set) var calls: [[String]] = []
    private var paneScript: [[PaneInfo]]
    private var failure: TmuxError?

    init(panes: [PaneInfo] = []) {
        paneScript = [panes]
    }

    /// Each list-panes call returns the next scripted list; the last one repeats.
    func script(_ lists: [[PaneInfo]]) -> Void {
        paneScript = lists
    }

    func failAll(with error: TmuxError?) -> Void {
        failure = error
    }

    func run(_ args: [String]) async throws -> String {
        calls.append(args)
        if let failure { throw failure }
        guard args.first == "list-panes" else { return "" }
        let list = paneScript.count > 1 ? paneScript.removeFirst() : (paneScript.first ?? [])
        return list.map { pane in
            [
                pane.sessionName, pane.paneID, String(pane.pid), String(pane.created), pane.isDead ? "1" : "0",
                pane.deadStatus.map(String.init) ?? "", pane.project, pane.kind?.rawValue ?? "", pane.name, pane.template,
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
