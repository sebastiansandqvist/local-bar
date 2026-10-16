import Foundation
import Darwin

public struct CaddyServiceStatus: Sendable {
    public var available: Bool
    public var managed: Bool
    public init(available: Bool = false, managed: Bool = false) {
        self.available = available; self.managed = managed
    }
}

public struct CaddyInstallationRequired: LocalizedError, Sendable {
    public var errorDescription: String? { "Caddy needs a one-time administrator setup to use port 80. Use the Caddy setup button to continue in Terminal." }
}

public actor CaddyService {
    public static let label = "app.localbar.caddy"
    public static let plist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    private let caddy: Caddy
    public let log: URL
    private let domain = "system"
    private var operating = false
    private var target: String { "\(domain)/\(Self.label)" }

    public init(paths: AppPaths = AppPaths()) {
        caddy = Caddy(paths: paths)
        log = paths.logs.appendingPathComponent("caddy.log")
    }
    private func job() async throws -> Job {
        let result = try await Commands.run("/bin/launchctl", ["print", target])
        if result.status != 0 && !result.output.lowercased().contains("could not find service") {
            throw LocalBarError("Cannot read Caddy's background service: \(result.output)")
        }
        return Job.parse(result)
    }
    public func status() async -> CaddyServiceStatus {
        async let available = caddy.isAvailable()
        let managed = (try? await job().loaded) == true
        return await CaddyServiceStatus(available: available, managed: managed)
    }
    public static func definition(settings: CaddySettings, log: URL, home: String = NSHomeDirectory()) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [settings.executable, "run", "--config", settings.config, "--adapter", "caddyfile"],
            "WorkingDirectory": URL(fileURLWithPath: settings.config).deletingLastPathComponent().path,
            "EnvironmentVariables": ["HOME": home, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ExitTimeOut": 8,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path
        ]
    }
    public func start(services: [Service], restart: Bool = false) async throws {
        guard !operating else { throw LocalBarError("Caddy is already being started.") }
        operating = true
        defer { operating = false }
        guard caddy.configured else { throw LocalBarError("Set up Caddy first with bash scripts/setup-caddy.sh from the Local Bar repo.") }
        let current = try await job()
        guard current.loaded else { throw CaddyInstallationRequired() }
        try await caddy.apply(services)
        if restart, await caddy.isAvailable() {
            // launchd restarts the service after a graceful stop, without another
            // administrator prompt or changing the dev server processes.
            try await stop(try caddy.settings())
        }
        try await waitUntilReady(previousPID: restart ? current.pid : nil)
    }

    // Called only by the setup helper after sudo. A system daemon is needed for
    // port 80; the ordinary app never writes into /Library/LaunchDaemons.
    public func install(services: [Service], home: String) async throws {
        guard geteuid() == 0 else { throw CaddyInstallationRequired() }
        guard !operating else { throw LocalBarError("Caddy setup is already in progress.") }
        operating = true
        defer { operating = false }
        let settings = try caddy.settings()
        let current = try await job()
        let available = await caddy.isAvailable()
        if !current.loaded && available {
            guard try await matchesRunningConfiguration(settings) else {
                throw LocalBarError("Caddy is running with another configuration. Stop it where it was started, then run setup again.")
            }
        } else if !current.loaded && !available {
            guard !(await Probes.portOpen(2019)), !(await Probes.portOpen(80)) else {
                throw LocalBarError("Port 80 or 2019 is already in use. Stop the conflicting server before starting Caddy.")
            }
        }
        try await caddy.apply(services)
        if current.loaded { try await launchctl(["bootout", target]) }
        else if available { try await stop(settings) }
        for _ in 0..<40 {
            let adminOpen = await Probes.portOpen(2019)
            let httpOpen = await Probes.portOpen(80)
            if !adminOpen && !httpOpen { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let data = try PropertyListSerialization.data(fromPropertyList: Self.definition(settings: settings, log: log, home: home), format: .xml, options: 0)
        try data.write(to: Self.plist, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: Self.plist.path)
        try await launchctl(["enable", target])
        try await launchctl(["bootstrap", domain, Self.plist.path])
        try await waitUntilReady()
    }
    private func waitUntilReady(previousPID: Int32? = nil) async throws {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            let current = try await job()
            if let pid = current.pid, pid != previousPID, await caddy.isAvailable() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw LocalBarError("Caddy hasn't become available. Choose Show logs from the Caddy menu for details.")
    }
    private func stop(_ settings: CaddySettings) async throws {
        let result = try await Commands.run(settings.executable, ["stop", "--config", settings.config, "--adapter", "caddyfile"])
        guard result.status == 0 else { throw LocalBarError("Couldn't stop Caddy.\n\n\(result.output)") }
    }
    private func launchctl(_ arguments: [String]) async throws {
        let result = try await Commands.run("/bin/launchctl", arguments)
        guard result.status == 0 else { throw LocalBarError("Couldn't start Caddy's background service.\n\n\(result.output)") }
    }
    private func matchesRunningConfiguration(_ settings: CaddySettings) async throws -> Bool {
        let adapted = try await Commands.run(settings.executable, ["adapt", "--config", settings.config, "--adapter", "caddyfile"])
        guard adapted.status == 0 else { throw LocalBarError("Couldn't read the saved Caddyfile.\n\n\(adapted.output)") }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:2019/config/")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let running = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let saved = try JSONSerialization.jsonObject(with: Data(adapted.standardOutput.utf8)) as? [AnyHashable: Any] else { return false }
        return running.isEqual(to: saved)
    }
}
