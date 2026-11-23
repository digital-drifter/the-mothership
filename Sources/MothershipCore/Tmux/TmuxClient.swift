import Foundation

public struct TmuxError: Error, Equatable {
    public var message: String
    public var exitCode: Int32

    public init(message: String, exitCode: Int32) {
        self.message = message
        self.exitCode = exitCode
    }
}

public struct SessionMetadata: Equatable, Sendable {
    public var project: String
    public var kind: ItemKind
    public var name: String
    public var template: String

    public init(project: String, kind: ItemKind, name: String, template: String) {
        self.project = project
        self.kind = kind
        self.name = name
        self.template = template
    }
}

public protocol TmuxCommanding: Sendable {
    func run(_ args: [String]) async throws -> String
}

public struct TmuxClient: TmuxCommanding {
    public let tmuxPath: String
    public let configPath: String
    public let socketName: String

    public init(tmuxPath: String, configPath: String, socketName: String = "mothership") {
        self.tmuxPath = tmuxPath
        self.configPath = configPath
        self.socketName = socketName
    }

    public func run(_ args: [String]) async throws -> String {
        let path = tmuxPath
        let arguments = ["-L", socketName, "-f", configPath] + args
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            let out = DataBox()
            let err = DataBox()
            let group = DispatchGroup()

            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: TmuxError(message: "\(error)", exitCode: -1))
                return
            }
            // Drain both pipes concurrently so a full pipe buffer can never stall tmux.
            for (pipe, box) in [(stdout, out), (stderr, err)] {
                group.enter()
                DispatchQueue.global().async {
                    box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
            }
            group.notify(queue: .global()) {
                let output = String(decoding: out.data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let message = String(decoding: err.data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: TmuxError(message: message, exitCode: process.terminationStatus))
                }
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

extension TmuxCommanding {
    private static func isNoServer(_ error: TmuxError) -> Bool {
        guard error.exitCode != -1 else { return false }
        return ["no server running", "error connecting"].contains { error.message.contains($0) }
    }

    /// tmux treats an argument ending in `;` as a command separator. A backslash before that
    /// trailing `;` makes tmux keep the `;` and strip exactly one backslash, so always add one.
    static func escapeTrailingSemicolon(_ arg: String) -> String {
        guard arg.hasSuffix(";") else { return arg }
        return "\(arg.dropLast())\\;"
    }

    public func listPanes() async throws -> [PaneInfo] {
        do {
            let output = try await run(["list-panes", "-a", "-F", PaneListFormat.format])
            return PaneListFormat.parse(output)
        } catch let error as TmuxError where Self.isNoServer(error) {
            return []
        }
    }

    public func newSession(name: String, directory: String, command: [String], metadata: SessionMetadata) async throws -> Void {
        var args = ["new-session", "-d", "-s", Self.escapeTrailingSemicolon(name), "-c", Self.escapeTrailingSemicolon(directory), "-x", "200", "-y", "50"]
        args += command.map(Self.escapeTrailingSemicolon)
        let options = [
            ("@ms_project", metadata.project), ("@ms_kind", metadata.kind.rawValue),
            ("@ms_name", metadata.name), ("@ms_template", metadata.template),
        ]
        for (key, value) in options {
            args += [";", "set-option", "-t", SessionName.target(name), key, Self.escapeTrailingSemicolon(value)]
        }
        _ = try await run(args)
    }

    /// Restarts the pane's process. Without `command` tmux reuses the pane's original command and directory;
    /// with one, the pane runs `command` in `directory` instead.
    public func respawn(session: String, directory: String? = nil, command: [String] = []) async throws -> Void {
        var args = ["respawn-pane", "-k"]
        if let directory { args += ["-c", Self.escapeTrailingSemicolon(directory)] }
        args += ["-t", SessionName.target(session)] + command.map(Self.escapeTrailingSemicolon)
        _ = try await run(args)
    }

    public func interrupt(session: String) async throws -> Void {
        _ = try await run(["send-keys", "-t", SessionName.target(session), "C-c"])
    }

    public func setName(session: String, name: String) async throws -> Void {
        _ = try await run(["set-option", "-t", SessionName.target(session), "@ms_name", Self.escapeTrailingSemicolon(name)])
    }

    public func killSession(_ name: String) async throws -> Void {
        _ = try await run(["kill-session", "-t", SessionName.target(name)])
    }

    public func killServer() async throws -> Void {
        do {
            _ = try await run(["kill-server"])
        } catch let error as TmuxError where Self.isNoServer(error) {
            return
        }
    }
}
