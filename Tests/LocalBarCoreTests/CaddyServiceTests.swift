import XCTest
@testable import LocalBarCore

final class CaddyServiceTests: XCTestCase {
    private func fixture(available: @escaping @Sendable () async -> Bool) throws -> (Caddy, URL) {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        let caddy = Caddy(paths: paths, available: available)
        let main = paths.root.appendingPathComponent("Caddyfile")
        try "import \"\(caddy.routes.path)\"\n".write(to: main, atomically: true, encoding: .utf8)
        let binary = paths.root.appendingPathComponent("fake-caddy")
        let commands = paths.root.appendingPathComponent("commands")
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$(dirname \"$0\")/commands\"\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try paths.write(CaddySettings(executable: binary.path, config: main.path), to: caddy.settingsFile)
        return (caddy, commands)
    }

    func testRunningExternalCaddyDoesNotRequireOurLaunchdJob() async throws {
        let (caddy, commands) = try fixture(available: { true })
        let service = CaddyService(caddy: caddy, readJob: {
            throw LocalBarError("A working Caddy installation must not need our launchd job.")
        })
        try await service.start(services: [])
        XCTAssertEqual(try String(contentsOf: commands), "validate\nreload\n")
    }

    func testRestartDoesNotStopOrAdoptExternalCaddy() async throws {
        let (caddy, commands) = try fixture(available: { true })
        let service = CaddyService(caddy: caddy, readJob: { Job(loaded: false, pid: nil, exitCode: nil) })
        do { try await service.start(services: [], restart: true); XCTFail("Must preserve external Caddy") }
        catch {
            XCTAssertFalse(error is CaddyInstallationRequired, "Restart must not open administrator setup for a working external installation")
            XCTAssertTrue(error.localizedDescription.contains("outside Local Bar"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: commands.path))
    }

    func testMissingServiceOnlyNeedsSetupWhenCaddyIsUnavailable() async throws {
        let (caddy, commands) = try fixture(available: { false })
        let service = CaddyService(caddy: caddy, readJob: { Job(loaded: false, pid: nil, exitCode: nil) })
        do { try await service.start(services: []); XCTFail("Expected setup action") }
        catch { XCTAssertTrue(error is CaddyInstallationRequired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: commands.path))
    }

    func testAvailabilitySurvivesAnUnreadableLaunchdJob() async throws {
        let (caddy, _) = try fixture(available: { true })
        let service = CaddyService(caddy: caddy, readJob: { throw LocalBarError("Service inspection failed") })
        let status = await service.status()
        XCTAssertTrue(status.available)
        XCTAssertFalse(status.managed)
    }

    func testExternalCaddyDisappearingDuringReloadIsNotReportedAsSuccessful() async throws {
        actor Availability {
            var checks = 0
            func check() -> Bool { checks += 1; return checks == 1 }
        }
        let availability = Availability()
        let (caddy, commands) = try fixture(available: { await availability.check() })
        let service = CaddyService(caddy: caddy, readJob: { Job(loaded: false, pid: nil, exitCode: nil) })
        do { try await service.start(services: []); XCTFail("Must not claim offline routes were applied") }
        catch {
            XCTAssertFalse(error is CaddyInstallationRequired)
            XCTAssertTrue(error.localizedDescription.contains("Caddy stopped"))
        }
        XCTAssertEqual(try String(contentsOf: commands), "validate\n")
    }
}
