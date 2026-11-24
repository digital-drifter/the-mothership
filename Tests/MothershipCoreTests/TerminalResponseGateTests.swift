import Foundation
import Testing
@testable import MothershipCore

@Suite struct TerminalResponseGateTests {
    @Test func testRepliesAreSuppressedOnTheFeedingThreadOnlyDuringTheFeed() -> Void {
        let gate = TerminalResponseGate()
        #expect(gate.allowsResponses)
        gate.whileFeeding {
            #expect(!gate.allowsResponses)
            gate.whileFeeding { #expect(!gate.allowsResponses) }
            #expect(!gate.allowsResponses)
        }
        #expect(gate.allowsResponses)
    }

    /// Output is parsed on a background thread; a mouse or focus report made on the main thread at the
    /// same moment comes from the user and must not be dropped.
    @Test func testAnotherThreadMayReplyWhileAFeedIsInProgress() -> Void {
        let gate = TerminalResponseGate()
        let feeding = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            gate.whileFeeding {
                feeding.signal()
                finish.wait()
            }
            done.signal()
        }
        feeding.wait()
        #expect(gate.allowsResponses)
        finish.signal()
        done.wait()
        #expect(gate.allowsResponses)
    }

    @Test func testTwoThreadsFeedingAtOnceAreEachSuppressed() -> Void {
        let gate = TerminalResponseGate()
        let results = NSLock()
        nonisolated(unsafe) var seen: [Bool] = []
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            Thread.detachNewThread {
                gate.whileFeeding {
                    Thread.sleep(forTimeInterval: 0.05)
                    let allowed = gate.allowsResponses
                    results.withLock { seen.append(allowed) }
                }
                group.leave()
            }
        }
        group.wait()
        #expect(seen == [false, false])
    }
}
