import XCTest
@testable import LocalBarCore

final class CommandDisplayTests: XCTestCase {
    func testRuntimeUsesFirstPATHMatchAndQuotesOnlyWhereNeeded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let binary = folder.appendingPathComponent("bun")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        }
        var service = Service(id: "test", group: "Test", name: "Test", directory: root.path,
            executable: first.appendingPathComponent("bun").path, arguments: ["run", "dev"],
            environment: ["PATH": first.path], url: "http://test.localhost", port: 3000)
        XCTAssertEqual(CommandDisplay.text(for: service), "bun run dev")
        service.environment["PATH"] = second.path + ":" + first.path
        XCTAssertTrue(CommandDisplay.text(for: service).hasPrefix(first.appendingPathComponent("bun").path))
        service.environment["PATH"] = first.path
        service.arguments = ["run", "a script", "$(touch nope)", "it's", ""]
        XCTAssertEqual(CommandDisplay.text(for: service), "bun run 'a script' '$(touch nope)' 'it'\\''s' ''")
        service.executable = "/bin/zsh"; service.arguments = ["-c", "bun dev"]
        XCTAssertEqual(CommandDisplay.text(for: service), "bun dev")
    }
}
