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
    /// The normal-screen cursor saved when the alternate screen was entered; used only when it is active.
    public var savedCursorX: Int
    public var savedCursorY: Int
    public var cursorVisible: Bool
    public var keypadCursor: Bool
    public var bracketedPaste: Bool
    public var mouseStandard: Bool
    public var mouseButton: Bool
    public var mouseAll: Bool
    public var mouseSGR: Bool

    public init(
        paneID: String = "", historyAndScreen: [String], alternateScreen: [String]? = nil,
        cursorX: Int, cursorY: Int, savedCursorX: Int = 0, savedCursorY: Int = 0, cursorVisible: Bool = true,
        keypadCursor: Bool = false, bracketedPaste: Bool = false,
        mouseStandard: Bool = false, mouseButton: Bool = false, mouseAll: Bool = false, mouseSGR: Bool = false
    ) {
        self.paneID = paneID
        self.historyAndScreen = historyAndScreen
        self.alternateScreen = alternateScreen
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.savedCursorX = savedCursorX
        self.savedCursorY = savedCursorY
        self.cursorVisible = cursorVisible
        self.keypadCursor = keypadCursor
        self.bracketedPaste = bracketedPaste
        self.mouseStandard = mouseStandard
        self.mouseButton = mouseButton
        self.mouseAll = mouseAll
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
/// The first line is a marker that names no target, so it succeeds whenever the client is attached;
/// a reader that sees the marker knows the next blocks belong to this snapshot, even if they fail.
///
/// Verified against tmux 3.8 while the alternate screen is active:
/// - `capture-pane` without `-a` returns the history plus the alternate (visible) screen.
/// - `capture-pane -a` returns the saved normal screen, without history.
/// - `-S -50000 -E -1` returns only history, except that with no history it returns the first visible line.
public enum SeedBuilder {
    public static let marker: String = "---ms-snapshot---"
    public static let snapshotReplyCount: Int = 5

    private static let headerFormat: String = [
        "#{alternate_on}", "#{cursor_x}", "#{cursor_y}", "#{alternate_saved_x}", "#{alternate_saved_y}",
        "#{cursor_flag}", "#{keypad_cursor_flag}", "#{bracket_paste_flag}", "#{mouse_standard_flag}",
        "#{mouse_button_flag}", "#{mouse_all_flag}", "#{mouse_sgr_flag}", "#{history_size}", "#{pane_id}",
    ].joined(separator: " ")
    private static let headerNumberCount = 13

    /// One tmux command per line; each produces exactly one reply block.
    public static func snapshotCommand(target: String) -> String {
        [
            "display-message -p -- '\(marker)'",
            "display-message -p -t \(target) '\(headerFormat)'",
            "capture-pane -p -e -J -S -50000 -E -1 -t \(target)",  // history
            "capture-pane -p -e -J -a -q -t \(target)",  // saved normal screen (alternate only)
            "capture-pane -p -e -J -t \(target)",  // visible screen
        ].joined(separator: "\n")
    }

    /// Parses the reply blocks of `snapshotCommand`, in order; nil for anything else.
    public static func parseSnapshot(_ replies: [[String]]) -> PaneSnapshot? {
        guard replies.count == snapshotReplyCount, replies[0] == [marker], replies[1].count == 1 else { return nil }
        let fields = replies[1][0].split(separator: " ")
        guard fields.count == headerNumberCount + 1 else { return nil }
        let numbers = fields.prefix(headerNumberCount).compactMap { Int($0) }
        guard numbers.count == headerNumberCount else { return nil }
        let isAlternate = numbers[0] == 1
        let history = numbers[12] > 0 ? replies[2] : []
        return PaneSnapshot(
            paneID: String(fields[headerNumberCount]),
            historyAndScreen: history + (isAlternate ? replies[3] : replies[4]),
            alternateScreen: isAlternate ? replies[4] : nil,
            cursorX: numbers[1], cursorY: numbers[2],
            savedCursorX: isAlternate ? numbers[3] : 0, savedCursorY: isAlternate ? numbers[4] : 0,
            cursorVisible: numbers[5] == 1, keypadCursor: numbers[6] == 1, bracketedPaste: numbers[7] == 1,
            mouseStandard: numbers[8] == 1, mouseButton: numbers[9] == 1, mouseAll: numbers[10] == 1,
            mouseSGR: numbers[11] == 1)
    }

    /// A full reset (RIS) that also shows the cursor, which RIS leaves as it was.
    static let reset: String = "\u{1b}c\u{1b}[?25h"

    /// Bytes that make a terminal show the snapshot. They start with a full reset, so feeding them into a
    /// view that already shows the pane (after a respawn or a reconnect) replaces its screen, scrollback
    /// and modes, as well as anything fed into it since.
    public static func build(_ snapshot: PaneSnapshot) -> [UInt8] {
        var seed = reset + snapshot.historyAndScreen.joined(separator: "\r\n")
        if let alternate = snapshot.alternateScreen {
            // ?1049h saves the cursor; put it where tmux saved it so leaving the alternate screen restores it.
            seed += "\u{1b}[\(snapshot.savedCursorY + 1);\(snapshot.savedCursorX + 1)H"
            seed += "\u{1b}[?1049h\u{1b}[H" + alternate.joined(separator: "\r\n")
        }
        seed += "\u{1b}[\(snapshot.cursorY + 1);\(snapshot.cursorX + 1)H"
        if snapshot.keypadCursor { seed += "\u{1b}[?1h" }
        if snapshot.mouseStandard { seed += "\u{1b}[?1000h" }
        if snapshot.mouseButton { seed += "\u{1b}[?1002h" }
        if snapshot.mouseAll { seed += "\u{1b}[?1003h" }
        if snapshot.mouseSGR { seed += "\u{1b}[?1006h" }
        if snapshot.bracketedPaste { seed += "\u{1b}[?2004h" }
        if !snapshot.cursorVisible { seed += "\u{1b}[?25l" }
        return Array(seed.utf8)
    }
}
