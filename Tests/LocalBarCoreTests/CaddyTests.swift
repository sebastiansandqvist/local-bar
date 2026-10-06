import XCTest
@testable import LocalBarCore

final class CaddyTests: XCTestCase {
    private func service(_ url: String = "http://example.localhost") -> Service {
        Service(id: "example", group: "Local", name: "Example", directory: "/tmp", executable: "/bin/echo", arguments: [], url: url, port: 3000)
    }

    func testRoutesAreLoopbackOnlyAndRejectInjectedOrRemoteAddresses() throws {
        let route = try Caddy.render([service()])
        XCTAssertTrue(route.contains("bind 127.0.0.1 ::1"))
        XCTAssertTrue(route.contains("reverse_proxy localhost:3000"))
        for url in ["http://example.com", "http://a.localhost/path", "http://a.localhost:80", "http://a.localhost\n}", "http://user@a.localhost", "https://a.localhost", "http://a..localhost"] {
            XCTAssertThrowsError(try Caddy.render([service(url)]), url)
        }
        XCTAssertThrowsError(try Caddy.render([service(), service("http://EXAMPLE.localhost/")]))
        XCTAssertNoThrow(try Caddy.render([]))
    }

    func testMigrationPreservesUnrelatedAndCustomRoutes() throws {
        let original = """
        { auto_https off }
        http://example.localhost {
            bind 127.0.0.1 ::1
            reverse_proxy 127.0.0.1:3000
        }
        http://other.localhost {
            respond "hello"
        }
        """
        let migrated = try Caddy.adoptingSimpleRoutes(in: original, services: [service()])
        XCTAssertFalse(migrated.contains("example.localhost"))
        XCTAssertTrue(migrated.contains("http://other.localhost"))
        XCTAssertTrue(migrated.contains("{ auto_https off }"))
        let custom = original.replacingOccurrences(of: "reverse_proxy 127.0.0.1:3000", with: "header X-Test yes\n    reverse_proxy 127.0.0.1:3000")
        XCTAssertEqual(try Caddy.adoptingSimpleRoutes(in: custom, services: [service()]), custom)
    }

    func testReloadFailureRestoresRouteFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.prepare()
        let caddy = Caddy(paths: paths)
        try "previous routes".write(to: caddy.routes, atomically: true, encoding: .utf8)
        let main = root.appendingPathComponent("Caddyfile")
        try "import \"\(caddy.routes.path)\"\n".write(to: main, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("fake-caddy")
        try "#!/bin/sh\n[ \"$1\" = validate ] && exit 0\necho 'reload unavailable'\nexit 1\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try paths.write(CaddySettings(executable: binary.path, config: main.path), to: caddy.settingsFile)
        do { try await caddy.apply([service()]); XCTFail("Expected reload failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reload unavailable")) }
        XCTAssertEqual(try String(contentsOf: caddy.routes), "previous routes")
        XCTAssertEqual(try String(contentsOf: main), "import \"\(caddy.routes.path)\"\n")
    }

    func testSuccessfulReloadAndRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.prepare()
        let caddy = Caddy(paths: paths)
        let main = root.appendingPathComponent("Caddyfile")
        try "import \"\(caddy.routes.path)\"".write(to: main, atomically: true, encoding: .utf8)
        try paths.write(CaddySettings(executable: "/usr/bin/true", config: main.path), to: caddy.settingsFile)
        try await caddy.apply([service()])
        XCTAssertTrue(try String(contentsOf: caddy.routes).contains("example.localhost"))
        try await caddy.apply([])
        XCTAssertFalse(try String(contentsOf: caddy.routes).contains("example.localhost"))
    }
}
