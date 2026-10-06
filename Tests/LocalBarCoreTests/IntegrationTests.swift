import XCTest
import Darwin
@testable import LocalBarCore

final class IntegrationTests: XCTestCase {
    private func fixture(ipv6: Bool = false) throws -> (Service, AppPaths) {
        guard ProcessInfo.processInfo.environment["LOCAL_BAR_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LOCAL_BAR_INTEGRATION=1 to exercise isolated launchd jobs and local ports.")
        }
        let id = "test-" + UUID().uuidString.lowercased()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("localbar-\(id)")
        let paths = AppPaths(root: root)
        try paths.prepare()
        let port = try freePort(ipv6: ipv6)
        let script = root.appendingPathComponent("server.py")
        try """
        import http.server, socket, subprocess, os
        child = subprocess.Popen(['/bin/sleep', '120'])
        with open('child.pid', 'w') as f: f.write(str(child.pid))
        class Server(http.server.HTTPServer):
            address_family = socket.AF_INET6 if \(ipv6 ? "True" : "False") else socket.AF_INET
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with open("requests.txt", "a") as requests: requests.write(self.path + "\\n")
                if self.path == '/host-check' and self.headers.get('Host') != 'test.localhost:\(port)':
                    self.send_response(400)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header('Via', '1.1 Caddy')
                self.end_headers()
                self.wfile.write(b'ok')
        Server(('\(ipv6 ? "::1" : "127.0.0.1")', \(port)), Handler).serve_forever()
        """.write(to: script, atomically: true, encoding: .utf8)
        let service = Service(id: id, group: "Test", name: "Fixture", directory: root.path,
                              executable: "/usr/bin/python3", arguments: ["-u", script.path],
                              url: "http://\(ipv6 ? "[::1]" : "127.0.0.1"):\(port)", port: port)
        addTeardownBlock {
            let manager = Launchd(paths: paths)
            if (try? await manager.job(service).loaded) == true { try await manager.stop(service) }
            try? FileManager.default.removeItem(at: root)
        }
        return (service, paths)
    }

    private func freePort(ipv6: Bool) throws -> Int {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalBarError("Cannot create test socket") }
        defer { close(fd) }
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            return try withUnsafeMutablePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    guard Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 else { throw LocalBarError("Cannot bind test socket") }
                    var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                    guard getsockname(fd, $0, &length) == 0 else { throw LocalBarError("Cannot inspect test socket") }
                    return Int(pointer.pointee.sin6_port.bigEndian)
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return try withUnsafeMutablePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    guard Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else { throw LocalBarError("Cannot bind test socket") }
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    guard getsockname(fd, $0, &length) == 0 else { throw LocalBarError("Cannot inspect test socket") }
                    return Int(pointer.pointee.sin_port.bigEndian)
                }
            }
        }
    }

    private func waitReady(_ service: Service, _ manager: Launchd) async throws -> Snapshot {
        for _ in 0..<40 {
            let snapshot = await Monitor.inspect(service, using: manager)
            if snapshot.state == .running { return snapshot }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let snapshot = await Monitor.inspect(service, using: manager)
        throw LocalBarError("Fixture not ready: \(snapshot.detail)")
    }

    func testDefaultMonitoringDoesNotRequestWebsite() async throws {
        let (service, paths) = try fixture()
        let manager = Launchd(paths: paths)
        try await manager.start(service)
        _ = try await waitReady(service, manager)
        for _ in 0..<3 { _ = await Monitor.inspect(service, using: manager) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("requests.txt").path))
    }

    func testExplicitHealthChecksUseOnlyConfiguredPath() async throws {
        var (service, paths) = try fixture()
        service.healthPath = "/health"
        let manager = Launchd(paths: paths)
        try await manager.start(service)
        _ = try await waitReady(service, manager)
        let requests = try String(contentsOf: paths.root.appendingPathComponent("requests.txt"))
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.split(separator: "\n").allSatisfy { $0 == "/health" })
    }

    func testStartReconnectRestartStopAndChildCleanup() async throws {
        let (service, paths) = try fixture()
        let manager = Launchd(paths: paths)
        try await manager.start(service)
        let first = try await waitReady(service, manager)
        let proxy = await Probes.proxy(URL(string: "http://test.localhost:\(service.port)/host-check")!)
        XCTAssertEqual(proxy.code, 200, "Localhost domain checks must retain the original Host header")
        XCTAssertTrue(proxy.server?.contains("Caddy") == true, "Recognize Caddy's Via header")
        let child = Int32(try String(contentsOf: paths.root.appendingPathComponent("child.pid")))!
        XCTAssertEqual(kill(child, 0), 0)
        let reconnected = try await Launchd(paths: paths).job(service)
        XCTAssertEqual(reconnected.pid, first.pid)
        try await manager.restart(service)
        let second = try await waitReady(service, manager)
        XCTAssertNotEqual(first.pid, second.pid)
        XCTAssertNotEqual(kill(child, 0), 0, "Restart must remove the original child process")
        let nextChild = Int32(try String(contentsOf: paths.root.appendingPathComponent("child.pid")))!
        try await manager.stop(service)
        let open = await Probes.portOpen(service.port)
        let job = try await manager.job(service)
        XCTAssertFalse(open)
        XCTAssertFalse(job.loaded)
        XCTAssertNotEqual(kill(nextChild, 0), 0, "Stop must remove child processes")
    }

    func testIPv6OnlyListenerIsRecognized() async throws {
        let (service, paths) = try fixture(ipv6: true)
        let manager = Launchd(paths: paths)
        try await manager.start(service)
        let snapshot = try await waitReady(service, manager)
        XCTAssertEqual(snapshot.state, .running)
        let open = await Probes.portOpen(service.port)
        XCTAssertTrue(open)
        try await manager.stop(service)
    }

    func testForeignListenerIsNeverStoppedOrReplaced() async throws {
        let (service, paths) = try fixture()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: service.executablePath)
        process.arguments = service.arguments
        process.currentDirectoryURL = paths.root
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate(); process.waitUntilExit()
            if let text = try? String(contentsOf: paths.root.appendingPathComponent("child.pid")), let child = Int32(text) { kill(child, SIGTERM) }
        }
        for _ in 0..<40 {
            if await Probes.portOpen(service.port) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let manager = Launchd(paths: paths)
        let snapshot = await Monitor.inspect(service, using: manager)
        XCTAssertEqual(snapshot.state, .external)
        do { try await manager.start(service); XCTFail("Must reject occupied port") } catch { XCTAssertTrue(error.localizedDescription.contains("already in use")) }
        do { try await manager.stop(service); XCTFail("Must reject unowned job") } catch { XCTAssertTrue(error.localizedDescription.contains("does not own")) }
        XCTAssertTrue(process.isRunning)
    }

    func testImmediateCrashRemainsVisibleUntilStopped() async throws {
        var (service, paths) = try fixture()
        service.executable = "/usr/bin/false"; service.arguments = []
        let manager = Launchd(paths: paths)
        try await manager.start(service)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let snapshot = await Monitor.inspect(service, using: manager)
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertTrue(snapshot.managed)
        try await manager.stop(service)
    }
}
