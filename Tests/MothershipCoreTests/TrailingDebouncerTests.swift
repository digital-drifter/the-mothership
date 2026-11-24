import Foundation
import Testing
@testable import MothershipCore

/// Waits until `condition` holds (the main actor may be busy with other tests), up to two seconds.
@MainActor
private func eventually(_ condition: () -> Bool) async throws -> Void {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite @MainActor struct TrailingDebouncerTests {
    @Test func testABurstDeliversOnlyTheLastValueOnce() async throws -> Void {
        var delivered: [Int] = []
        let debouncer = TrailingDebouncer<Int>(delay: .milliseconds(40)) { delivered.append($0) }
        debouncer.submit(1)
        debouncer.submit(2)
        debouncer.submit(3)
        #expect(delivered.isEmpty)
        try await eventually { !delivered.isEmpty }
        // Nothing else follows the one delivery.
        try await Task.sleep(for: .milliseconds(100))
        #expect(delivered == [3])
    }

    @Test func testValuesSeparatedByAPauseAreEachDelivered() async throws -> Void {
        var delivered: [Int] = []
        let debouncer = TrailingDebouncer<Int>(delay: .milliseconds(20)) { delivered.append($0) }
        debouncer.submit(1)
        try await eventually { delivered == [1] }
        debouncer.submit(2)
        try await eventually { delivered.count == 2 }
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
