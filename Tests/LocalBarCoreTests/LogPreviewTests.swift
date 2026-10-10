import XCTest
import CoreGraphics
@testable import LocalBarCore

final class LogPreviewTests: XCTestCase {
    func testPreviewStaysBesideRowAndWithinScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menu = CGRect(x: 1020, y: 200, width: 410, height: 680)
        let side = LogPreviewPlacement.side(menu: menu, screen: screen, width: 420)
        XCTAssertEqual(side, .left)
        let row = CGRect(x: 1020, y: 400, width: 410, height: 49)
        let size = CGSize(width: 420, height: 200)
        let middle = LogPreviewPlacement.frame(row: row, menu: menu, screen: screen, size: size, side: side)
        XCTAssertEqual(middle.midY, row.midY)
        XCTAssertEqual(middle.maxX, menu.minX - 10)
        for y in [0.0, 880.0] {
            let edgeRow = CGRect(x: row.minX, y: y, width: row.width, height: row.height)
            let frame = LogPreviewPlacement.frame(row: edgeRow, menu: menu, screen: screen, size: size, side: side)
            XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
            XCTAssertEqual(frame.minX, middle.minX)
        }
        let otherScreen = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        let leftMenu = CGRect(x: -1190, y: 100, width: 410, height: 680)
        XCTAssertEqual(LogPreviewPlacement.side(menu: leftMenu, screen: otherScreen, width: 420), .right)
    }

    func testOnlyActiveManagedStatesOfferPreview() {
        for state in [ServiceState.running, .starting, .restarting] { XCTAssertTrue(state.canPreviewLogs) }
        for state in [ServiceState.off, .external, .checking, .failed, .unknown, .stopping, .unresponsive] {
            XCTAssertFalse(state.canPreviewLogs)
        }
    }

    func testSmallPreviewTailKeepsColorsAndHandlesStartup() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = LogReader(maximumBytes: 512, maximumLines: 10, emptyMessage: "Waiting for output…")
        let missing = await reader.read(file)
        XCTAssertEqual(missing.text, "Waiting for output…")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let empty = await reader.read(file)
        XCTAssertEqual(empty.text, "Waiting for output…")
        let raw = String(repeating: "older output\n", count: 1000) + "\u{1b}[33mWARN\u{1b}[0m starting"
        try raw.write(to: file, atomically: true, encoding: .utf8)
        let tail = await reader.read(file)
        XCTAssertTrue(tail.text.hasSuffix("WARN starting"))
        XCTAssertEqual(tail.text.components(separatedBy: "\n").count, 10)
        XCTAssertLessThanOrEqual(tail.text.utf8.count, 512)
        XCTAssertEqual(tail.runs.last?.style.foreground, .indexed(3))
    }
}
