import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let standardOutput: String
    public init(status: Int32, output: String, standardOutput: String? = nil) {
        self.status = status; self.output = output; self.standardOutput = standardOutput ?? output
    }
}

public enum Commands {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) async throws -> CommandResult {
        let command = CommandExecution(executable, arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { command.start($0) }
        } onCancel: { command.cancel() }
    }
}

// File-backed output avoids waiting forever for a child that inherited a pipe.
// All process state, cancellation, and completion are confined to this queue.
private final class CommandExecution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.localbar.command")
    private let process = Process()
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var files: [(URL, FileHandle)] = []
    private var timer: DispatchSourceTimer?
    private var cancelled = false

    init(_ executable: String, _ arguments: [String], timeout: TimeInterval) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        self.timeout = timeout
    }
    func start(_ continuation: CheckedContinuation<CommandResult, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(CancellationError())); return }
            do {
                for _ in 0..<2 {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("localbar-command-\(UUID().uuidString)")
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    files.append((url, try FileHandle(forWritingTo: url)))
                }
                process.standardOutput = files[0].1; process.standardError = files[1].1
                process.terminationHandler = { [self] _ in queue.async { [self] in completed() } }
                try process.run()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { [self] in
                    interrupt()
                    finish(.failure(LocalBarError("\(process.executableURL!.lastPathComponent) timed out after \(Int(timeout)) seconds.")))
                }
                self.timer = timer
                timer.resume()
            } catch { finish(.failure(error)) }
        }
    }
    func cancel() {
        queue.async { [self] in
            cancelled = true
            interrupt()
            finish(.failure(CancellationError()))
        }
    }
    private func interrupt() {
        guard process.isRunning else { return }
        process.terminate()
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    private func completed() {
        guard continuation != nil else { return }
        let output = files.map { file -> String in
            guard let reader = try? FileHandle(forReadingFrom: file.0) else { return "" }
            defer { try? reader.close() }
            return String(decoding: (try? reader.read(upToCount: 262_144)) ?? Data(), as: UTF8.self)
        }
        finish(.success(CommandResult(status: process.terminationStatus, output: output.joined(), standardOutput: output.first ?? "")))
    }
    private func finish(_ result: Result<CommandResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        process.terminationHandler = nil
        timer?.cancel(); timer = nil
        for (url, handle) in files { try? handle.close(); try? FileManager.default.removeItem(at: url) }
        files = []
        continuation.resume(with: result)
    }
}
