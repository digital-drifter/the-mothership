import Foundation
import Testing
@testable import MothershipCore

@Suite @MainActor struct TrailingDebouncerTests {
    @Test func testABurstDeliversOnlyTheLastValueOnce() async throws -> Void {
        var delivered: [Int] = []
        let debouncer = TrailingDebouncer<Int>(delay: .milliseconds(40)) { delivered.append($0) }
        debouncer.submit(1)
        debouncer.submit(2)
        debouncer.submit(3)
        #expect(delivered.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(delivered == [3])
    }

    @Test func testValuesSeparatedByAPauseAreEachDelivered() async throws -> Void {
        var delivered: [Int] = []
        let debouncer = TrailingDebouncer<Int>(delay: .milliseconds(20)) { delivered.append($0) }
        debouncer.submit(1)
        try await Task.sleep(for: .milliseconds(150))
        debouncer.submit(2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(delivered == [1, 2])
    }

    @Test func testCancelDropsThePendingValue() async throws -> Void {
        var delivered: [Int] = []
        let debouncer = TrailingDebouncer<Int>(delay: .milliseconds(20)) { delivered.append($0) }
        debouncer.submit(1)
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(120))
        #expect(delivered.isEmpty)
    }
}
