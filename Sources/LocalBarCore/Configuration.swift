import Foundation

public struct Service: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var group: String
    public var name: String
    public var directory: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var url: String
    public var port: Int
    public var healthPath: String?
    public var startupTimeout: Double

    public init(id: String, group: String, name: String, directory: String, executable: String,
                arguments: [String], environment: [String: String] = [:], url: String,
                port: Int, healthPath: String? = nil, startupTimeout: Double = 30) {
        self.id = id; self.group = group; self.name = name; self.directory = directory
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.url = url; self.port = port; self.healthPath = healthPath; self.startupTimeout = startupTimeout
    }

    public var label: String { "app.localbar.service.\(id)" }
    public var folder: URL { URL(fileURLWithPath: (directory as NSString).expandingTildeInPath) }
    public var executablePath: String { (executable as NSString).expandingTildeInPath }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
            throw LocalBarError("Invalid service ID: \(id). Use lowercase letters, numbers, and hyphens.")
        }
        guard (1...65535).contains(port), startupTimeout >= 1, startupTimeout <= 300,
              !name.isEmpty, !group.isEmpty, executablePath.hasPrefix("/"),
              (directory as NSString).expandingTildeInPath.hasPrefix("/") else {
            throw LocalBarError("Check the name, group, paths, port, and startup timeout for \(id).")
        }
        guard let address = URL(string: url), ["http", "https"].contains(address.scheme), address.host != nil else {
            throw LocalBarError("\(id) needs an HTTP or HTTPS URL.")
        }
        if let healthPath, !healthPath.hasPrefix("/") || healthPath.hasPrefix("//") {
            throw LocalBarError("The health path for \(id) must start with a single slash.")
        }
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var services: [Service]
    public init(services: [Service]) { self.services = services }
    public func validate() throws {
        guard Set(services.map(\.id)).count == services.count else { throw LocalBarError("Service IDs must be unique.") }
        guard Set(services.map(\.port)).count == services.count else { throw LocalBarError("Each service needs its own port.") }
        guard Set(services.map { $0.url.lowercased() }).count == services.count else { throw LocalBarError("Each service needs its own domain.") }
        try services.forEach { try $0.validate() }
    }

    public static func defaults(home: String = NSHomeDirectory()) -> Configuration {
        Configuration(services: [])
    }

    public static func runtimePath(home: String = NSHomeDirectory()) -> String {
        let roots = ["\(home)/.local/share/nvm", "\(home)/.nvm/versions/node"]
        let bins = roots.flatMap { root -> [String] in
            ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(root)/\($0)/bin" }
                .filter { FileManager.default.isExecutableFile(atPath: "\($0)/node") }
        }
        return (["\(home)/.bun/bin"] + bins + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    }

}

public struct LocalBarError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct AppPaths: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Local Bar", isDirectory: true)
    }
    public var config: URL { root.appendingPathComponent("services.json") }
    public var agents: URL { root.appendingPathComponent("Agents", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public func plist(_ service: Service) -> URL { agents.appendingPathComponent("\(service.label).plist") }
    public func record(_ service: Service) -> URL { agents.appendingPathComponent("\(service.label).json") }
    public func log(_ service: Service) -> URL { logs.appendingPathComponent("\(service.id).log") }
    public func prepare() throws {
        for folder in [root, agents, logs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
    public func load() throws -> Configuration {
        try prepare()
        if !FileManager.default.fileExists(atPath: config.path) { try write(Configuration.defaults(), to: config) }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: config))
        try value.validate()
        return value
    }
    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
