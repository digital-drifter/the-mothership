import Foundation
import Testing
@testable import MothershipCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Void { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Polls until the counter reaches `target` or the timeout elapses.
private func waitForCount(_ counter: Counter, atLeast target: Int, timeout: Duration = .seconds(2)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if counter.count >= target { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return counter.count >= target
}

@Test func testFiresOnInPlaceWrite() async throws -> Void {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("projects.yml")
    try "projects: []\n".write(to: file, atomically: false, encoding: .utf8)

    let counter = Counter()
    let watcher = ConfigWatcher(url: file) { counter.increment() }
    watcher.start()
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(100))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("# edited\n".utf8))
    try handle.close()

    #expect(await waitForCount(counter, atLeast: 1))
}

@Test func testFiresOnAtomicReplace() async throws -> Void {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("projects.yml")
    try "projects: []\n".write(to: file, atomically: false, encoding: .utf8)

    let counter = Counter()
    let watcher = ConfigWatcher(url: file) { counter.increment() }
    watcher.start()
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(100))
    let temp = dir.appendingPathComponent("projects.yml.tmp")
    try "projects:\n  - name: New\n    path: /tmp\n".write(to: temp, atomically: false, encoding: .utf8)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)

    #expect(await waitForCount(counter, atLeast: 1))
}

@Test func testFiresWhenFileIsDeleted() async throws -> Void {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("projects.yml")
    try "projects: []\n".write(to: file, atomically: false, encoding: .utf8)

    let counter = Counter()
    let watcher = ConfigWatcher(url: file) { counter.increment() }
    watcher.start()
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(100))
    try FileManager.default.removeItem(at: file)

    #expect(await waitForCount(counter, atLeast: 1))
}

@Test func testFiresOnceForABurstOfWrites() async throws -> Void {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("projects.yml")
    try "projects: []\n".write(to: file, atomically: false, encoding: .utf8)

    let counter = Counter()
    let watcher = ConfigWatcher(url: file) { counter.increment() }
    watcher.start()
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(100))
    for index in 1...5 {
        let temp = dir.appendingPathComponent("burst-\(index).tmp")
        try String(repeating: "x", count: index * 10).write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await waitForCount(counter, atLeast: 1))
    try await Task.sleep(for: .milliseconds(650))
    #expect(counter.count == 1)
}

@Test func testIgnoresOtherFilesInDirectory() async throws -> Void {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("projects.yml")
    try "projects: []\n".write(to: file, atomically: false, encoding: .utf8)

    let counter = Counter()
    let watcher = ConfigWatcher(url: file) { counter.increment() }
    watcher.start()
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(100))
    try "noise".write(to: dir.appendingPathComponent("other.txt"), atomically: false, encoding: .utf8)

    try await Task.sleep(for: .milliseconds(500))
    #expect(counter.count == 0)
}

@Test func testStopPreventsFurtherCallbacksAndIsIdempotent() async throws -> Void {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("projects.yml")
    try "projects: []\n".write(to: file, atomically: false, encoding: .utf8)

    let counter = Counter()
    let watcher = ConfigWatcher(url: file) { counter.increment() }
    watcher.start()
    try await Task.sleep(for: .milliseconds(100))
    watcher.stop()
    watcher.stop()

    try "changed contents".write(to: file, atomically: false, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(500))
    #expect(counter.count == 0)
}
