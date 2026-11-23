import Foundation

/// What a pane looked like at the moment its snapshot was taken.
public struct PaneSnapshot: Equatable, Sendable {
    public var paneID: String
    /// The normal grid including history, with SGR (`-e`) and joined wraps (`-J`).
    public var historyAndScreen: [String]
    /// The alternate screen; non-nil only when `alternate_on`.
    public var alternateScreen: [String]?
    public var cursorX: Int
    public var cursorY: Int
    public var keypadCursor: Bool
    public var mouseAny: Bool
    public var mouseSGR: Bool

    public init(
        paneID: String = "", historyAndScreen: [String], alternateScreen: [String]? = nil,
        cursorX: Int, cursorY: Int, keypadCursor: Bool = false, mouseAny: Bool = false, mouseSGR: Bool = false
    ) {
        self.paneID = paneID
        self.historyAndScreen = historyAndScreen
        self.alternateScreen = alternateScreen
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.keypadCursor = keypadCursor
        self.mouseAny = mouseAny
        self.mouseSGR = mouseSGR
    }
}

/// Captures a pane through control mode and turns the capture into bytes that recreate it in a terminal.
///
/// tmux 3.8 answers every command with its own reply block, even when commands are joined with ` ; `,
/// so the snapshot is several commands, one per line, answered by `snapshotReplyCount` blocks in order.
/// The lines are written to tmux in a single write, so tmux queues and runs them back to back with no
/// pane output processed in between.
///
/// Verified against tmux 3.8 while the alternate screen is active:
/// - `capture-pane` without `-a` returns the history plus the alternate (visible) screen.
/// - `capture-pane -a` returns the saved normal screen, without history.
/// - `-S -50000 -E -1` returns only history, except that with no history it returns the first visible line.
public enum SeedBuilder {
    public static let marker: String = "---ms-snapshot---"
    public static let snapshotReplyCount: Int = 4

    private static let headerFormat: String =
        "#{alternate_on} #{cursor_x} #{cursor_y} #{keypad_cursor_flag} #{mouse_any_flag} #{mouse_sgr_flag} #{history_size} #{pane_id}"

    /// One tmux command per line; each produces exactly one reply block.
    public static func snapshotCommand(target: String) -> String {
        [
            "display-message -p -t \(target) -- '\(marker) \(headerFormat)'",
            "capture-pane -p -e -J -S -50000 -E -1 -t \(target)",  // history
            "capture-pane -p -e -J -a -q -t \(target)",  // saved normal screen (alternate only)
            "capture-pane -p -e -J -t \(target)",  // visible screen
        ].joined(separator: "\n")
    }

    /// Parses the reply blocks of `snapshotCommand`, in order; nil for anything else.
    public static func parseSnapshot(_ replies: [[String]]) -> PaneSnapshot? {
        guard replies.count == snapshotReplyCount, replies[0].count == 1 else { return nil }
        let fields = replies[0][0].split(separator: " ")
        guard fields.count == 9, fields[0] == marker else { return nil }
        let numbers = fields[1...7].compactMap { Int($0) }
        guard numbers.count == 7 else { return nil }
        let isAlternate = numbers[0] == 1
        let history = numbers[6] > 0 ? replies[1] : []
        return PaneSnapshot(
            paneID: String(fields[8]),
            historyAndScreen: history + (isAlternate ? replies[2] : replies[3]),
            alternateScreen: isAlternate ? replies[3] : nil,
            cursorX: numbers[1], cursorY: numbers[2],
            keypadCursor: numbers[3] == 1, mouseAny: numbers[4] == 1, mouseSGR: numbers[5] == 1)
    }

    public static func build(_ snapshot: PaneSnapshot) -> [UInt8] {
        var seed = "\u{1b}[0m" + snapshot.historyAndScreen.joined(separator: "\r\n")
        if let alternate = snapshot.alternateScreen {
            seed += "\u{1b}[?1049h\u{1b}[H" + alternate.joined(separator: "\r\n")
        }
        seed += "\u{1b}[\(snapshot.cursorY + 1);\(snapshot.cursorX + 1)H"
        if snapshot.keypadCursor { seed += "\u{1b}[?1h" }
        if snapshot.mouseAny { seed += "\u{1b}[?1000h\u{1b}[?1003h" }
        if snapshot.mouseSGR { seed += "\u{1b}[?1006h" }
        return Array(seed.utf8)
    }
}
