import XCTest
@testable import LocalBarCore

final class ANSILogTests: XCTestCase {
    func testColorsStylesResetsAndUnicodeRanges() {
        let content = ANSILog.parse("plain 🙂\u{1b}[1;2;3;4;31;44mred 🥂\u{1b}[22;23;24;39;49m end")
        XCTAssertEqual(content.text, "plain 🙂red 🥂 end")
        XCTAssertEqual(content.runs.count, 1)
        let run = content.runs[0]
        XCTAssertEqual((content.text as NSString).substring(with: run.range), "red 🥂")
        XCTAssertEqual(run.range.location, 8)
        XCTAssertEqual(run.style.foreground, .indexed(1))
        XCTAssertEqual(run.style.background, .indexed(4))
        XCTAssertTrue(run.style.bold && run.style.dim && run.style.italic && run.style.underline)
    }

    func testExtendedColorsAndColonSyntax() {
        let content = ANSILog.parse("\u{1b}[38;5;200mA\u{1b}[48;2;10;20;30mB\u{1b}[0;38:2::1:2:3mC\u{1b}[0mD")
        XCTAssertEqual(content.text, "ABCD")
        XCTAssertEqual(content.runs.map(\.style.foreground), [.indexed(200), .indexed(200), .rgb(1, 2, 3)])
        XCTAssertEqual(content.runs[1].style.background, .rgb(10, 20, 30))
    }

    func testControlStringsAreRemovedWithoutPerformingTerminalActions() {
        let raw = "\u{1b}]0;title\u{7}\u{1b}]52;c;clipboard\u{1b}\\\u{1b}]8;;https://example.com\u{7}link\u{1b}]8;;\u{1b}\\\u{1b}[2J\u{1b}[H\u{7}\r\nnext\rprogress"
        XCTAssertEqual(ANSILog.parse(raw).text, "link\nnext\nprogress")
        XCTAssertEqual(ANSILog.parse("hello\u{1b}[38;2;").text, "hello")
        XCTAssertEqual(ANSILog.parse("hello\u{1b}]8;;incomplete").text, "hello")
    }

    func testClippedLinesKeepStylesAndMalformedColorsStayBounded() {
        let content = ANSILog.parse("\u{1b}[32mold\nkeep\nlast", maximumLines: 2)
        XCTAssertEqual(content.text, "keep\nlast")
        XCTAssertEqual(content.runs[0].range, NSRange(location: 0, length: 9))
        XCTAssertEqual(content.runs[0].style.foreground, .indexed(2))
        let malformed = ANSILog.parse("\u{1b}[38;5;999mA\u{1b}[38;2;-1;0;0mB\u{1b}[999999999999999999999999999999999999mC")
        XCTAssertEqual(malformed.text, "ABC")
        XCTAssertTrue(malformed.runs.isEmpty)
    }
}
