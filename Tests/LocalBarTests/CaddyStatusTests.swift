import XCTest
@testable import LocalBar
@testable import LocalBarCore

@MainActor final class CaddyStatusTests: XCTestCase {
    private actor Installation {
        var available: Bool
        var managed: Bool
        init(available: Bool, managed: Bool) { self.available = available; self.managed = managed }
        func update(available: Bool, managed: Bool) { self.available = available; self.managed = managed }
        func isAvailable() -> Bool { available }
        func job() -> Job { Job(loaded: managed, pid: managed ? 1 : nil, exitCode: nil) }
    }

    private func fixture(available: Bool, managed: Bool) throws -> (Store, Installation) {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.prepare()
        try paths.write(Configuration(services: []), to: paths.config)
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        let installation = Installation(available: available, managed: managed)
        let caddy = Caddy(paths: paths, available: { await installation.isAvailable() })
        let main = paths.root.appendingPathComponent("Caddyfile")
        try "import \"\(caddy.routes.path)\"\n".write(to: main, atomically: true, encoding: .utf8)
        // Failing validation also detects accidental startup/reload attempts.
        try paths.write(CaddySettings(executable: "/usr/bin/false", config: main.path), to: caddy.settingsFile)
        let service = CaddyService(caddy: caddy, readJob: { await installation.job() })
        return (Store(paths: paths, startMonitoring: false, caddy: caddy, caddyService: service), installation)
    }

    func testCheckingDoesNotFlashASetupButton() throws {
        let (store, _) = try fixture(available: true, managed: true)
        XCTAssertEqual(store.caddyStatus, "Checking")
        XCTAssertNil(store.caddyActionTitle)
        XCTAssertNil(store.caddyError)
    }

    func testStartupAcceptsExistingCaddyWithEitherServiceManager() async throws {
        for managed in [false, true] {
            let (store, _) = try fixture(available: true, managed: managed)
            await store.prepareCaddy()
            XCTAssertEqual(store.caddyStatus, "Available")
            XCTAssertEqual(store.caddyState.managed, managed)
            XCTAssertNil(store.caddyActionTitle)
            XCTAssertNil(store.caddyError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.caddy.routes.path), "Startup must leave healthy Caddy alone")
        }
    }

    func testSetupActionDisappearsWhenSetupCompletesWithoutPersistentWarning() async throws {
        let (store, installation) = try fixture(available: false, managed: false)
        await store.prepareCaddy()
        XCTAssertEqual(store.caddyActionTitle, "Set up…")
        XCTAssertNil(store.caddyError)
        await store.runCaddy()
        XCTAssertNil(store.caddyError, "Missing setup must not become a sticky error")
        await installation.update(available: true, managed: true)
        await store.checkCaddy()
        XCTAssertEqual(store.caddyStatus, "Available")
        XCTAssertNil(store.caddyActionTitle)
        XCTAssertNil(store.caddyError)
    }

    func testSetupActionAlsoDisappearsWhenExternalCaddyStarts() async throws {
        let (store, installation) = try fixture(available: false, managed: false)
        await store.prepareCaddy()
        XCTAssertEqual(store.caddyActionTitle, "Set up…")
        await installation.update(available: true, managed: false)
        await store.checkCaddy()
        XCTAssertEqual(store.caddyStatus, "Available")
        XCTAssertFalse(store.caddyState.managed)
        XCTAssertNil(store.caddyActionTitle)
        XCTAssertNil(store.caddyError)
    }

    func testInstalledButStoppedCaddyOffersStart() async throws {
        let (store, _) = try fixture(available: false, managed: true)
        await store.checkCaddy()
        XCTAssertEqual(store.caddyActionTitle, "Start")
        XCTAssertNil(store.caddyError)
    }

    func testWorkingListenerDoesNotHideConfigurationFailure() async throws {
        let (store, _) = try fixture(available: true, managed: false)
        await store.runCaddy()
        XCTAssertEqual(store.caddyStatus, "Available")
        XCTAssertTrue(store.caddyError?.contains("configuration is invalid") == true)
        await store.checkCaddy()
        XCTAssertNotNil(store.caddyError, "Availability alone doesn't mean a failed configuration was fixed")
        var settings = try store.caddy.settings()
        settings.executable = "/usr/bin/true"
        try store.paths.write(settings, to: store.caddy.settingsFile)
        await store.runCaddy()
        XCTAssertNil(store.caddyError)
        XCTAssertNil(store.caddyActionTitle)
    }
}
