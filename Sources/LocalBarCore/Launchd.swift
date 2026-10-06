import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum Commands {
    public static func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

public struct Job: Sendable {
    public let loaded: Bool
    public let pid: Int32?
    public let exitCode: Int?
    public static func parse(_ result: CommandResult) -> Job {
        func integer(_ key: String) -> Int? {
            for line in result.output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\(key) = ") { return Int(trimmed.dropFirst(key.count + 3)) }
            }
            return nil
        }
        return Job(loaded: result.status == 0, pid: integer("pid").flatMap(Int32.init(exactly:)), exitCode: integer("last exit code"))
    }
}

public actor Launchd {
    public let paths: AppPaths
    private let domain: String
    private var operations: Set<String> = []
    public init(paths: AppPaths = AppPaths()) { self.paths = paths; domain = "gui/\(getuid())" }
    private func target(_ service: Service) -> String { "\(domain)/\(service.label)" }

    public func job(_ service: Service) async throws -> Job {
        let result = try await Commands.run("/bin/launchctl", ["print", target(service)])
        if result.status != 0 && !result.output.contains("Could not find service") && !result.output.contains("could not find service") {
            throw LocalBarError("Cannot read the macOS service manager: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return Job.parse(result)
    }

    public func recordedService(_ service: Service) -> Service {
        guard let data = try? Data(contentsOf: paths.record(service)),
              let saved = try? JSONDecoder().decode(Service.self, from: data), saved.id == service.id else { return service }
        return saved
    }

    public static func definition(_ service: Service, log: URL) -> [String: Any] {
        var environment = service.environment
        if environment["PATH"] == nil { environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        environment["HOME"] = NSHomeDirectory()
        return [
            "Label": service.label,
            "ProgramArguments": [service.executablePath] + service.arguments,
            "WorkingDirectory": service.folder.path,
            "EnvironmentVariables": environment,
            "RunAtLoad": true,
            "KeepAlive": false,
            "AbandonProcessGroup": false,
            "ExitTimeOut": 8,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path
        ]
    }

    public func start(_ service: Service) async throws {
        guard operations.insert(service.id).inserted else { throw LocalBarError("An operation is already in progress.") }
        defer { operations.remove(service.id) }
        try await startJob(service)
    }

    private func startJob(_ service: Service) async throws {
        try service.validate()
        guard !(try await job(service)).loaded else { throw LocalBarError("This service is already managed. Use Restart to start it again.") }
        guard !(await Probes.portOpen(service.port)) else {
            throw LocalBarError("Port \(service.port) is already in use. Stop the existing server in its terminal, then start it here.")
        }
        guard FileManager.default.fileExists(atPath: service.folder.path) else { throw LocalBarError("Project folder not found: \(service.folder.path)") }
        guard FileManager.default.isExecutableFile(atPath: service.executablePath) else { throw LocalBarError("Executable not found: \(service.executablePath). Update services.json.") }
        try paths.prepare()
        let log = paths.log(service)
        if let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
            let previous = log.appendingPathExtension("previous")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: log, to: previous)
        }
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let data = try PropertyListSerialization.data(fromPropertyList: Self.definition(service, log: log), format: .xml, options: 0)
        try data.write(to: paths.plist(service), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.plist(service).path)
        try paths.write(service, to: paths.record(service))
        let result = try await Commands.run("/bin/launchctl", ["bootstrap", domain, paths.plist(service).path])
        guard result.status == 0 else { throw LocalBarError("Could not start \(service.name): \(result.output)") }
    }

    public func stop(_ service: Service) async throws {
        guard operations.insert(service.id).inserted else { throw LocalBarError("An operation is already in progress.") }
        defer { operations.remove(service.id) }
        try await stopJob(service)
    }

    private func stopJob(_ service: Service) async throws {
        guard (try await job(service)).loaded else {
            throw LocalBarError("Local Bar does not own this server. Stop it in the terminal that started it.")
        }
        let original = recordedService(service)
        // bootout terminates the registered job and its process group, never an arbitrary port owner.
        let result = try await Commands.run("/bin/launchctl", ["bootout", target(service)])
        guard result.status == 0 else { throw LocalBarError("Could not stop \(service.name): \(result.output)") }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if !(await Probes.portOpen(original.port)) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LocalBarError("The managed job stopped, but port \(original.port) is still occupied. Local Bar will not kill an unrelated process.")
    }

    public func restart(_ service: Service) async throws {
        guard operations.insert(service.id).inserted else { throw LocalBarError("An operation is already in progress.") }
        defer { operations.remove(service.id) }
        try await stopJob(service)
        try await startJob(service)
    }
}
