import Testing
@testable import MothershipCore

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

@Suite struct ControlModeParserTests {
    @Test func testDecodesOctalEscapes() -> Void {
        #expect(ControlModeParser.decodeOctal("a\\033[1mb\\134") == [0x61, 0x1b, 0x5b, 0x31, 0x6d, 0x62, 0x5c])
    }

    @Test func testDecodesDoubleBackslashAndLoneBackslash() -> Void {
        #expect(ControlModeParser.decodeOctal("\\\\x\\") == [0x5c, 0x78, 0x5c])
    }

    @Test func testParsesOutputEvent() -> Void {
        var p = ControlModeParser()
        #expect(p.feed(bytes("%output %3 hi\\015\\012\n")) == [.output(paneID: "%3", data: [0x68, 0x69, 13, 10])])
    }

    @Test func testOutputPreservesInvalidUTF8AndCarriageReturn() -> Void {
        var p = ControlModeParser()
        let events = p.feed(bytes("%output %1 ") + [0xff, 0xfe, 0x0d, 0x0a])
        #expect(events == [.output(paneID: "%1", data: [0xff, 0xfe, 0x0d])])
    }

    @Test func testParsesExtendedOutput() -> Void {
        var p = ControlModeParser()
        #expect(p.feed(bytes("%extended-output %3 120 : x\n")) == [.output(paneID: "%3", data: [0x78])])
    }

    @Test func testParsesReplyBlockWithPercentLinesInside() -> Void {
        var p = ControlModeParser()
        let input = "%begin 100 7 1\n%output %1 inside\n%end 99 8 1\nplain\n%end 100 7 1\n"
        #expect(p.feed(bytes(input)) == [.reply(number: 7, lines: ["%output %1 inside", "%end 99 8 1", "plain"], isError: false)])
    }

    @Test func testParsesEmptyReply() -> Void {
        var p = ControlModeParser()
        #expect(p.feed(bytes("%begin 1 2 0\r\n%end 1 2 0\r\n")) == [.reply(number: 2, lines: [], isError: false)])
    }

    @Test func testParsesErrorReply() -> Void {
        var p = ControlModeParser()
        let events = p.feed(bytes("%begin 1 5 1\nbad thing\n%error 1 5 1\n"))
        #expect(events == [.reply(number: 5, lines: ["bad thing"], isError: true)])
    }

    @Test func testHandlesLineSplitAcrossFeeds() -> Void {
        var p = ControlModeParser()
        #expect(p.feed(bytes("%outp")).isEmpty)
        #expect(p.feed(bytes("ut %1 a\n")) == [.output(paneID: "%1", data: [0x61])])
    }

    @Test func testOutputBetweenBlocksPreservesOrder() -> Void {
        var p = ControlModeParser()
        let input = "%begin 1 1 1\na\n%end 1 1 1\n%output %2 z\n%begin 2 2 1\nb\n%end 2 2 1\n"
        #expect(p.feed(bytes(input)) == [
            .reply(number: 1, lines: ["a"], isError: false),
            .output(paneID: "%2", data: [0x7a]),
            .reply(number: 2, lines: ["b"], isError: false),
        ])
    }

    @Test func testParsesExitWithAndWithoutReason() -> Void {
        var p = ControlModeParser()
        #expect(p.feed(bytes("%exit\n%exit server exited\n")) == [.exit(reason: nil), .exit(reason: "server exited")])
    }

    @Test func testUnknownNotificationPassesThrough() -> Void {
        var p = ControlModeParser()
        #expect(p.feed(bytes("%window-renamed @1 x\r\n")) == [.notification("%window-renamed @1 x")])
    }

    @Test func testStripsLeadingDCSPrefix() -> Void {
        var p = ControlModeParser()
        #expect(p.feed(bytes("\u{1b}P1000p%output %1 a\n")) == [.output(paneID: "%1", data: [0x61])])
    }

    @Test func testLargeOutputBurstIsLinear() -> Void {
        var p = ControlModeParser()
        let line = bytes("%output %1 " + String(repeating: "x", count: 1000) + "\n")
        var blob: [UInt8] = []
        for _ in 0..<1024 { blob += line }
        var total = 0
        var count = 0
        // feed in uneven chunks so lines straddle feeds
        var i = 0
        while i < blob.count {
            let end = min(i + 4093, blob.count)
            for case .output(_, let d) in p.feed(Array(blob[i..<end])) { total += d.count; count += 1 }
            i = end
        }
        #expect(count == 1024)
        #expect(total == 1024 * 1000)
    }
}
