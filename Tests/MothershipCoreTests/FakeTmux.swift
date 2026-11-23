import Foundation
@testable import MothershipCore

actor FakeTmux: TmuxCommanding {
    private(set) var calls: [[String]] = []
    private var paneScript: [[PaneInfo]]
    private var failure: TmuxError?
    private var argvFailures: [[String]: TmuxError] = [:]
    private var holdNextList = false
    private var held: [CheckedContinuation<Void, Never>] = []

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

    /// Any call with exactly this argv throws `error`.
    func fail(_ args: [String], with error: TmuxError) -> Void {
        argvFailures[args] = error
    }

    /// The next list-panes call takes its list right away but only returns once `releaseHeld()` runs.
    func holdNextListPanes() -> Void {
        holdNextList = true
    }

    var heldCount: Int { held.count }

    func releaseHeld() -> Void {
        held.forEach { $0.resume() }
        held = []
    }

    func run(_ args: [String]) async throws -> String {
        calls.append(args)
        if let failure { throw failure }
        if let error = argvFailures[args] { throw error }
        if args.count == 5, args[0] == "set-option", args[3] == "@ms_name" {
            applyName(args[4], toTarget: args[2])
            return ""
        }
        guard args.first == "list-panes" else { return "" }
        let list = paneScript.count > 1 ? paneScript.removeFirst() : (paneScript.first ?? [])
        if holdNextList {
            holdNextList = false
            await withCheckedContinuation { held.append($0) }
        }
        return list.map { pane in
            [
                pane.sessionName, pane.paneID, String(pane.pid), String(pane.created), pane.isDead ? "1" : "0",
                pane.deadStatus.map(String.init) ?? "", pane.project, pane.kind?.rawValue ?? "", pane.name, pane.template,
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Mimics `set-option -t =session: @ms_name name` on every scripted pane of that session.
    private func applyName(_ name: String, toTarget target: String) -> Void {
        let session = target.trimmingCharacters(in: CharacterSet(charactersIn: "=:"))
        paneScript = paneScript.map { list in
            list.map { pane in
                guard pane.sessionName == session else { return pane }
                var renamed = pane
                renamed.name = name
                return renamed
            }
        }
    }
}
