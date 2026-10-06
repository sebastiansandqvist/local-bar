import XCTest
@testable import LocalBarCore

final class CoreTests: XCTestCase {
    private func sample(_ id: String = "example", port: Int = 3000) -> Service {
        Service(id: id, group: "Local", name: "Example", directory: "/tmp", executable: "/bin/echo", arguments: ["hello"], url: "http://\(id).localhost", port: port)
    }

    func testFreshInstallStartsEmpty() throws {
        let config = Configuration.defaults(home: "/Users/test")
        try config.validate()
        XCTAssertTrue(config.services.isEmpty)
    }

    func testRejectsDuplicatePortsAndUnsafeIdentifiers() throws {
        var config = Configuration(services: [sample(), sample("second", port: 3001)])
        config.services[1].port = config.services[0].port
        XCTAssertThrowsError(try config.validate())
        var service = config.services[0]
        service.id = "../../another-job"
        XCTAssertThrowsError(try service.validate())
        service.id = "valid"
        service.healthPath = "//external.example"
        XCTAssertThrowsError(try service.validate())
    }

    func testLaunchDefinitionOwnsProcessGroupWithoutAutomaticRestarts() throws {
        var service = sample()
        service.arguments = ["run", "a script; echo ignored"]
        let definition = Launchd.definition(service, log: URL(fileURLWithPath: "/tmp/log"))
        XCTAssertEqual(definition["ProgramArguments"] as? [String], [service.executablePath] + service.arguments)
        XCTAssertEqual(definition["KeepAlive"] as? Bool, false)
        XCTAssertEqual(definition["AbandonProcessGroup"] as? Bool, false)
        XCTAssertEqual(definition["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(definition["WorkingDirectory"] as? String, service.folder.path)
    }

    func testJobParserDistinguishesMissingExitedAndRunning() {
        XCTAssertFalse(Job.parse(CommandResult(status: 113, output: "Could not find service")).loaded)
        let running = Job.parse(CommandResult(status: 0, output: "job = {\n\tpid = 123\n\tlast exit code = 1\n}"))
        XCTAssertEqual(running.pid, 123)
        XCTAssertEqual(running.exitCode, 1)
        let exited = Job.parse(CommandResult(status: 0, output: "job = {\n\tlast exit code = 2\n}"))
        XCTAssertTrue(exited.loaded)
        XCTAssertNil(exited.pid)
    }

    func testExternalListenerNeverBecomesOwnedEvenWhenHTTPFails() {
        let snapshot = Snapshot.evaluate(job: Job(loaded: false, pid: nil, exitCode: nil), portOpen: true,
                                         direct: HTTPResult(code: nil, server: nil), proxy: HTTPResult(code: nil, server: nil), hasHealthCheck: false)
        XCTAssertEqual(snapshot.state, .external)
        XCTAssertFalse(snapshot.managed)
    }

    func testBackend404MeansReachableUnlessHealthEndpointConfigured() {
        let job = Job(loaded: true, pid: 123, exitCode: nil)
        let direct = HTTPResult(code: 404, server: nil)
        let proxy = HTTPResult(code: 404, server: "Caddy")
        XCTAssertEqual(Snapshot.evaluate(job: job, portOpen: true, direct: direct, proxy: proxy, hasHealthCheck: false).state, .running)
        XCTAssertEqual(Snapshot.evaluate(job: job, portOpen: true, direct: direct, proxy: proxy, hasHealthCheck: true).state, .unresponsive)
    }

    func testProxyFailureIsSeparateFromServiceFailure() {
        let result = Snapshot.evaluate(job: Job(loaded: true, pid: 123, exitCode: nil), portOpen: true,
                                       direct: HTTPResult(code: 200, server: nil), proxy: HTTPResult(code: 502, server: "Caddy"), hasHealthCheck: false)
        XCTAssertEqual(result.state, .running)
        XCTAssertTrue(result.routeWarning)
        XCTAssertTrue(result.caddyDetected)
    }

    func testExitedJobCannotBeMistakenForHealthyForeignListener() {
        let result = Snapshot.evaluate(job: Job(loaded: true, pid: nil, exitCode: 1), portOpen: true,
                                       direct: HTTPResult(code: 200, server: nil), proxy: HTTPResult(code: 200, server: nil), hasHealthCheck: false)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.managed)
    }
}
