import Foundation
import LocalBarCore

@main struct Setup {
    static func main() async {
        do { try await setup() }
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
            let arguments = ["--config", root.path, "--adapter", "caddyfile"]
            let validation = try await Commands.run(binary, ["validate"] + arguments)
            guard validation.status == 0 else { throw LocalBarError(validation.output) }
            let reload = try await Commands.run(binary, ["reload"] + arguments)
            if reload.status != 0 {
                // Never start a second server on top of an existing listener.
                guard !(await Probes.portOpen(2019)), !(await Probes.portOpen(80)) else { throw LocalBarError(reload.output) }
                let start = try await Commands.run(binary, ["start"] + arguments)
                guard start.status == 0 else { throw LocalBarError(start.output) }
            }
            try paths.write(CaddySettings(executable: binary, config: root.path), to: caddy.settingsFile)
            print("Caddy is ready. Local Bar will update its routes when you save servers.")
        } catch {
            if let previousRoot { try previousRoot.write(to: root, options: .atomic) }
            else { try? FileManager.default.removeItem(at: root) }
            if let previousRoutes { try previousRoutes.write(to: caddy.routes, options: .atomic) }
            else { try? FileManager.default.removeItem(at: caddy.routes) }
            throw error
        }
    }
}
