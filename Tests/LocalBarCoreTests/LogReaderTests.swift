import XCTest
@testable import LocalBarCore

final class LogReaderTests: XCTestCase {
    func testBoundedTailAndRotation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("server.log")
        try (String(repeating: "old line\n", count: 30_000) + "\u{001B}[31mlatest\u{001B}[0m\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = LogReader()
        let tail = await reader.read(file)
        XCTAssertTrue(tail.hasSuffix("latest\n"))
        XCTAssertLessThanOrEqual(tail.components(separatedBy: "\n").count, 2000)
        XCTAssertFalse(tail.contains("\u{001B}"))
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("previous.log"))
        try "new log\n".write(to: file, atomically: true, encoding: .utf8)
        let rotated = await reader.read(file)
        XCTAssertEqual(rotated, "new log\n")
    }
}
