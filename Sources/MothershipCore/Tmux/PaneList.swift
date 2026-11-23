import Foundation

public struct PaneInfo: Equatable, Sendable {
    public var sessionName: String
    public var paneID: String
    public var pid: Int32
    public var created: Int
    public var isDead: Bool
    public var deadStatus: Int?
    public var project: String
    public var kind: ItemKind?
    public var name: String
    public var template: String

    public init(
        sessionName: String, paneID: String, pid: Int32, created: Int, isDead: Bool, deadStatus: Int?,
        project: String, kind: ItemKind?, name: String, template: String
    ) {
        self.sessionName = sessionName
        self.paneID = paneID
        self.pid = pid
        self.created = created
        self.isDead = isDead
        self.deadStatus = deadStatus
        self.project = project
        self.kind = kind
        self.name = name
        self.template = template
    }
}

public enum PaneListFormat {
    public static let format: String = [
        "#{session_name}", "#{pane_id}", "#{pane_pid}", "#{session_created}", "#{pane_dead}",
        "#{pane_dead_status}", "#{@ms_project}", "#{@ms_kind}", "#{@ms_name}", "#{@ms_template}",
    ].joined(separator: "\t")

    public static func parse(_ output: String) -> [PaneInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> PaneInfo? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10, fields[0].hasPrefix("ms-") else { return nil }
            return PaneInfo(
                sessionName: fields[0],
                paneID: fields[1],
                pid: Int32(fields[2]) ?? 0,
                created: Int(fields[3]) ?? 0,
                isDead: fields[4] == "1",
                deadStatus: Int(fields[5]),
                project: fields[6],
                kind: ItemKind(rawValue: fields[7]),
                name: fields[8],
                template: fields[9]
            )
        }
    }
}
