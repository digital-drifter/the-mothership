import Foundation

public enum ControlEvent: Equatable, Sendable {
    case reply(number: Int, lines: [String], isError: Bool)
    case output(paneID: String, data: [UInt8])
    case exit(reason: String?)
    case notification(String)
}

/// Incremental parser for the byte stream produced by `tmux -C`.
public struct ControlModeParser: Sendable {
    private static let newline: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let percent: UInt8 = 0x25
    private static let space: UInt8 = 0x20
    private static let backslash: UInt8 = 0x5C
    private static let dcsPrefix: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]

    private struct Block: Sendable {
        var number: Int
        var lines: [String] = []
    }

    private var buffer: [UInt8] = []
    /// Bytes of `buffer` already searched for a newline (no rescanning of partial lines).
    private var scanned: Int = 0
    private var block: Block?
    private var atStreamStart: Bool = true

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [ControlEvent] {
        buffer.append(contentsOf: bytes)
        var events: [ControlEvent] = []
        var lineStart = 0
        var index = scanned
        let data = buffer
        while index < data.count {
            if data[index] == Self.newline {
                var slice = data[lineStart..<index]
                if atStreamStart {
                    atStreamStart = false
                    if slice.starts(with: Self.dcsPrefix) { slice = slice.dropFirst(Self.dcsPrefix.count) }
                }
                if let event = handle(line: slice) { events.append(event) }
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart > 0 { buffer = Array(data[lineStart...]) }
        scanned = buffer.count
        return events
    }

    public static func decodeOctal(_ text: Substring) -> [UInt8] {
        decodeOctal(ArraySlice(text.utf8))
    }

    static func decodeOctal(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = input.startIndex
        let end = input.endIndex
        while i < end {
            let b = input[i]
            guard b == backslash else { out.append(b); i += 1; continue }
            if i + 1 < end, input[i + 1] == backslash {
                out.append(backslash)
                i += 2
            } else if i + 3 < end, isOctal(input[i + 1]), isOctal(input[i + 2]), isOctal(input[i + 3]) {
                let value = Int(input[i + 1] - 0x30) * 64 + Int(input[i + 2] - 0x30) * 8 + Int(input[i + 3] - 0x30)
                out.append(UInt8(truncatingIfNeeded: value))
                i += 4
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    // MARK: - Line handling

    private static func isOctal(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }

    private mutating func handle(line raw: ArraySlice<UInt8>) -> ControlEvent? {
        if var current = block {
            let trimmed = Self.strippingCR(raw)
            if let end = Self.blockEnd(trimmed), end.number == current.number {
                block = nil
                return .reply(number: current.number, lines: current.lines, isError: end.isError)
            }
            current.lines.append(String(decoding: raw, as: UTF8.self))
            block = current
            return nil
        }
        guard raw.first == Self.percent else {
            // Stray non-% line outside a block; surface it rather than dropping it.
            return .notification(String(decoding: Self.strippingCR(raw), as: UTF8.self))
        }
        if let output = Self.parseOutput(raw) { return output }
        let line = String(decoding: Self.strippingCR(raw), as: UTF8.self)
        if line.hasPrefix("%begin "), let number = Self.number(in: line) {
            block = Block(number: number)
            return nil
        }
        if line == "%exit" { return .exit(reason: nil) }
        if line.hasPrefix("%exit ") { return .exit(reason: String(line.dropFirst(6))) }
        return .notification(line)
    }

    private static func strippingCR(_ s: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        s.last == carriageReturn ? s.dropLast() : s
    }

    /// `%output %<id> <data>` and `%extended-output %<id> <age> : <data>`; data is never CR-stripped.
    private static func parseOutput(_ line: ArraySlice<UInt8>) -> ControlEvent? {
        let output = Array("%output ".utf8)
        let extended = Array("%extended-output ".utf8)
        let isExtended = line.starts(with: extended)
        guard isExtended || line.starts(with: output) else { return nil }
        let idStart = line.startIndex + (isExtended ? extended.count : output.count)
        guard let idEnd = line[idStart...].firstIndex(of: space) ?? (isExtended ? nil : line.endIndex) else { return nil }
        let paneID = String(decoding: line[idStart..<idEnd], as: UTF8.self)
        var dataStart = min(idEnd + 1, line.endIndex)
        if isExtended {
            // Skip "<age> ... : " up to the first " : ".
            let separator: [UInt8] = [space, 0x3A, space]
            var found: Int?
            var j = dataStart
            while j + 3 <= line.endIndex {
                if line[j] == separator[0], line[j + 1] == separator[1], line[j + 2] == separator[2] { found = j; break }
                j += 1
            }
            guard let j = found else { return nil }
            dataStart = j + 3
        }
        return .output(paneID: paneID, data: decodeOctal(line[dataStart...]))
    }

    private static func fields(_ line: ArraySlice<UInt8>) -> [Substring] {
        String(decoding: line, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: true)
    }

    /// `%begin <time> <number> <flags>` → number
    private static func number(in line: String) -> Int? {
        let parts = line.split(separator: " ")
        return parts.count >= 3 ? Int(parts[2]) : nil
    }

    private static func blockEnd(_ line: ArraySlice<UInt8>) -> (number: Int, isError: Bool)? {
        guard line.first == percent else { return nil }
        let parts = fields(line)
        guard parts.count >= 3, parts[0] == "%end" || parts[0] == "%error", let n = Int(parts[2]) else { return nil }
        return (n, parts[0] == "%error")
    }
}
