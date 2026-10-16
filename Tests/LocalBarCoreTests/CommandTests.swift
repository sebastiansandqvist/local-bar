import XCTest
@testable import LocalBarCore

final class CommandTests: XCTestCase {
    func testCapturesStdoutAndDiagnosticsSeparately() async throws {
        let result = try await Commands.run("/bin/sh", ["-c", "echo output; echo diagnostic >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.standardOutput, "output\n")
        XCTAssertTrue(result.output.contains("diagnostic"))
    }
    func testInheritedOutputHandleDoesNotBlockCompletion() async throws {
        let start = Date()
        let result = try await Commands.run("/bin/sh", ["-c", "/bin/sleep 2 & echo done"], timeout: 1)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("done"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
    func testTimeoutTerminatesAnUnresponsiveCommand() async throws {
        let start = Date()
        do {
            _ = try await Commands.run("/bin/sleep", ["30"], timeout: 0.2)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testCancellationReturnsPromptly() async throws {
        let task = Task { try await Commands.run("/bin/sleep", ["30"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
