import Foundation
import Testing
@testable import MothershipCore

@Suite struct ByteBatcherTests {
    @Test func testOnlyTheFirstAppendOfABatchAsksForADrain() -> Void {
        let batcher = ByteBatcher()
        #expect(batcher.append([1, 2]) == true)
        #expect(batcher.append([3]) == false)
        #expect(batcher.append([4, 5]) == false)
    }

    @Test func testDrainReturnsEverythingInOrderAndStartsANewBatch() -> Void {
        let batcher = ByteBatcher()
        _ = batcher.append([1, 2])
        _ = batcher.append([3])
        #expect(batcher.drain() == [1, 2, 3])
        #expect(batcher.drain() == [])
        #expect(batcher.append([9]) == true)
        #expect(batcher.drain() == [9])
    }

    @Test func testConcurrentAppendsLoseNothing() async -> Void {
        let batcher = ByteBatcher()
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<8 {
                group.addTask { for _ in 0..<500 { _ = batcher.append([UInt8(value)]) } }
            }
        }
        let drained = batcher.drain()
        #expect(drained.count == 4000)
        for value in 0..<8 { #expect(drained.filter { $0 == UInt8(value) }.count == 500) }
    }
}
