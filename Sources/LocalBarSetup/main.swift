import Foundation
import Darwin
import LocalBarCore

@main struct Setup {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "--install-service" {
                try await installService()
            } else { try await setup() }
        }
        catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }

    static func setup() async throws {
        let paths = AppPaths()
        let config = try paths.load()
        let caddy = Caddy(paths: paths)
        let binary = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/caddy" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary else { throw LocalBarError("Install Caddy first: brew install caddy") }
        let saved = try? JSONDecoder().decode(CaddySettings.self, from: Data(contentsOf: caddy.settingsFile))
        let argument = CommandLine.arguments.dropFirst().first
        let root = URL(fileURLWithPath: (argument as NSString?)?.expandingTildeInPath ?? saved?.config ?? paths.root.appendingPathComponent("Caddyfile").path)
        let adminRunning = await Probes.portOpen(2019)
        let httpRunning = await Probes.portOpen(80)
        if argument == nil && saved == nil && (adminRunning || httpRunning) {
            throw LocalBarError("Caddy or another server is already running. Pass your existing Caddyfile: bash scripts/setup-caddy.sh /path/to/Caddyfile")
        }
        let previousRoot = try? Data(contentsOf: root)
        let previousRoutes = try? Data(contentsOf: caddy.routes)
        let previousSettings = try? Data(contentsOf: caddy.settingsFile)
        var contents = previousRoot.map { String(decoding: $0, as: UTF8.self) } ?? "{\n\tauto_https off\n\tadmin 127.0.0.1:2019\n}\n"
        // Adopt only exact, simple loopback proxies. Custom blocks remain untouched.
        contents = try Caddy.adoptingSimpleRoutes(in: contents, services: config.services)
        let line = "import \"\(caddy.routes.path)\""
        if !contents.components(separatedBy: .newlines).contains(line) { contents += "\n\(line)\n" }
        if let previousRoot {
            let backup = root.appendingPathExtension("localbar-backup-\(UUID().uuidString)")
            try previousRoot.write(to: backup, options: .atomic)
            print("Backup: \(backup.path)")
        }
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Caddy.render(config.services).write(to: caddy.routes, atomically: true, encoding: .utf8)
            try contents.write(to: root, atomically: true, encoding: .utf8)
            try paths.write(CaddySettings(executable: binary, config: root.path), to: caddy.settingsFile)
            try await caddy.apply(config.services)
            print("Caddy configuration is ready.")
        } catch {
            if let previousRoot { try previousRoot.write(to: root, options: .atomic) }
            else { try? FileManager.default.removeItem(at: root) }
            if let previousRoutes { try previousRoutes.write(to: caddy.routes, options: .atomic) }
            else { try? FileManager.default.removeItem(at: caddy.routes) }
            if let previousSettings { try previousSettings.write(to: caddy.settingsFile, options: .atomic) }
            else { try? FileManager.default.removeItem(at: caddy.settingsFile) }
            throw error
        }
    }
    static func installService() async throws {
        guard geteuid() == 0, CommandLine.arguments.count == 3,
              let uidText = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = UInt32(uidText),
              let user = getpwuid(uid) else { throw LocalBarError("Run the setup script from your own account. It will ask for administrator access.") }
        let home = String(cString: user.pointee.pw_dir)
        let gid = user.pointee.pw_gid
        let paths = AppPaths(root: URL(fileURLWithPath: CommandLine.arguments[2]))
        let expected = AppPaths(root: URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Local Bar"))
        guard paths.root.standardizedFileURL == expected.root.standardizedFileURL else {
            throw LocalBarError("Use the Local Bar configuration belonging to the account running sudo.")
        }
        let config = try paths.load()
        defer {
            // Caddy's files stay editable by the user after the privileged setup.
            for file in [paths.config, Caddy(paths: paths).routes, paths.logs.appendingPathComponent("caddy.log")] {
                try? FileManager.default.setAttributes([.ownerAccountID: uid, .groupOwnerAccountID: gid, .posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        try await CaddyService(paths: paths).install(services: config.services, home: home)
        print("Caddy is ready and will start automatically at boot.")
    }

}
