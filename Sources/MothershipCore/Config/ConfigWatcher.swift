import Foundation

/// Watches a single config file for changes and calls `onChange` (debounced).
///
/// Editors usually save by writing a temp file and renaming it over the original, so a file
/// descriptor on the file itself would go stale. So this watches the parent directory (which sees
/// renames, creations and deletions) and compares the file's modification date and size with the
/// last seen values. Directory events do not fire for in-place writes, so a second source on the
/// file itself covers those; it is re-opened after every check because a rename makes it stale.
public final class ConfigWatcher: @unchecked Sendable {
    private struct Signature: Equatable {
        let modified: Date
        let size: Int
    }

    private static let debounce: DispatchTimeInterval = .milliseconds(150)

    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "mothership.config-watcher")

    // All mutable state below is only touched on `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var lastSignature: Signature?

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        // Cancelling the source closes the descriptor via its cancel handler.
        source?.cancel()
        fileSource?.cancel()
    }

    /// Begins watching. The parent directory must exist. Calling it twice has no extra effect.
    public func start() -> Void {
        queue.sync {
            guard source == nil else { return }
            let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
            guard descriptor >= 0 else { return }

            lastSignature = currentSignature()

            source = makeSource(descriptor: descriptor, mask: .write)
            reopenFileSource()
        }
    }

    /// Stops watching and closes the descriptor. Safe to call more than once.
    public func stop() -> Void {
        queue.sync {
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
            fileSource?.cancel()
            fileSource = nil
        }
    }

    private func makeSource(descriptor: Int32, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject {
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: queue)
        newSource.setEventHandler { [weak self] in self?.scheduleCheck() }
        newSource.setCancelHandler { close(descriptor) }
        newSource.resume()
        return newSource
    }

    /// Points the file-level source at the file's current inode (or none if it is missing).
    private func reopenFileSource() -> Void {
        fileSource?.cancel()
        fileSource = nil
        guard source != nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        fileSource = makeSource(descriptor: descriptor, mask: [.write, .extend, .delete, .rename])
    }

    private func scheduleCheck() -> Void {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkForChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }

    private func checkForChange() -> Void {
        reopenFileSource()
        let signature = currentSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        onChange()
    }

    /// Nil when the file does not exist.
    private func currentSignature() -> Signature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return Signature(modified: modified, size: size.intValue)
    }
}
