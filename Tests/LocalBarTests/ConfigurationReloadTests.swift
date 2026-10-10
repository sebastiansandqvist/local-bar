import XCTest
@testable import LocalBar
import LocalBarCore

@MainActor final class ConfigurationReloadTests: XCTestCase {
    private func fixture() throws -> (Store, AppPaths, Configuration) {
        let id = "test-" + UUID().uuidString.lowercased()
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(id))
        try paths.prepare()
        let service = Service(id: id, group: "Test", name: "Original", directory: paths.root.path,
                              executable: "/bin/sleep", arguments: ["60"], url: "http://\(id).localhost", port: 49999)
        let config = Configuration(services: [service])
        try paths.write(config, to: paths.config)
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        return (Store(paths: paths, startMonitoring: false), paths, config)
    }

    func testAtomicSaveAppliesRoutesWithoutRewritingTheSavedFile() async throws {
        let (store, paths, initial) = try fixture()
        await store.reloadSavedConfiguration()
        var changed = initial
        changed.services[0].name = "Updated"
        changed.services[0].port = 49998
        let data = Data(" \n".utf8) + (try JSONEncoder().encode(changed)) + Data("\n\n".utf8)
        try data.write(to: paths.config, options: .atomic)
        await store.reloadSavedConfiguration()
        XCTAssertEqual(store.services, changed.services)
        XCTAssertNil(store.configurationError)
        XCTAssertEqual(try Data(contentsOf: paths.config), data)
        XCTAssertTrue(try String(contentsOf: Caddy(paths: paths).routes).contains("localhost:49998"))
    }

    func testInvalidAndMissingSavesKeepWorkingConfigurationAndRecover() async throws {
        let (store, paths, initial) = try fixture()
        await store.reloadSavedConfiguration()
        let routes = try Data(contentsOf: Caddy(paths: paths).routes)
        for data in [Data("{".utf8), try JSONEncoder().encode(Configuration(services: initial.services + initial.services))] {
            try data.write(to: paths.config, options: .atomic)
            await store.reloadSavedConfiguration()
            XCTAssertEqual(store.services, initial.services)
            XCTAssertNotNil(store.configurationError)
            XCTAssertEqual(try Data(contentsOf: Caddy(paths: paths).routes), routes)
            XCTAssertEqual(try Data(contentsOf: paths.config), data)
        }
        try FileManager.default.removeItem(at: paths.config)
        await store.reloadSavedConfiguration()
        XCTAssertEqual(store.services, initial.services)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.config.path))
        try paths.write(initial, to: paths.config)
        await store.reloadSavedConfiguration()
        XCTAssertNil(store.configurationError)
    }

    func testBusyServiceDefersReloadAndUsesLatestSave() async throws {
        let (store, paths, initial) = try fixture()
        await store.reloadSavedConfiguration()
        store.busy.insert(initial.services[0].id)
        var changed = initial
        changed.services[0].name = "First save"
        try paths.write(changed, to: paths.config)
        await store.reloadSavedConfiguration()
        XCTAssertEqual(store.services, initial.services)
        changed.services[0].name = "Latest save"
        try paths.write(changed, to: paths.config)
        store.busy.removeAll()
        await store.reloadSavedConfiguration()
        XCTAssertEqual(store.services, changed.services)
    }

    func testFailedCaddyReloadPreservesStateAndRetriesSameSave() async throws {
        let (store, paths, initial) = try fixture()
        await store.reloadSavedConfiguration()
        let caddy = Caddy(paths: paths)
        let originalRoutes = try Data(contentsOf: caddy.routes)
        let main = paths.root.appendingPathComponent("Caddyfile")
        try "import \"\(caddy.routes.path)\"\n".write(to: main, atomically: true, encoding: .utf8)
        try paths.write(CaddySettings(executable: "/usr/bin/false", config: main.path), to: caddy.settingsFile)
        var changed = initial
        changed.services[0].port = 49998
        try paths.write(changed, to: paths.config)
        await store.reloadSavedConfiguration()
        XCTAssertEqual(store.services, initial.services)
        XCTAssertNotNil(store.configurationError)
        XCTAssertEqual(try Data(contentsOf: caddy.routes), originalRoutes)
        XCTAssertEqual(try paths.load(), changed)
        try paths.write(CaddySettings(executable: "/usr/bin/true", config: main.path), to: caddy.settingsFile)
        await store.reloadSavedConfiguration()
        XCTAssertEqual(store.services, changed.services)
        XCTAssertNil(store.configurationError)
    }
}
