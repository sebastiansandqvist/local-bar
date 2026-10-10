import XCTest
@testable import LocalBarCore

final class LogThemeTests: XCTestCase {
    func testGhosttyUsesDefaultsAndResolvedOverrides() throws {
        let defaults = "background = #000000\nforeground = #eeeeee\n" + (0..<16).map { "palette = \($0)=#123456" }.joined(separator: "\n")
        let theme = try LogThemeImport.ghostty(defaults: defaults, current: """
        background = #20242d
        palette = 1=#bf616a
        font-family = Zed Mono
        font-size = 16
        selection-background = #495469
        """)
        XCTAssertEqual(theme.background, TerminalColor(hex: "20242d"))
        XCTAssertEqual(theme.palette[1], TerminalColor(hex: "bf616a"))
        XCTAssertEqual(theme.palette[15], TerminalColor(hex: "123456"))
        XCTAssertEqual(theme.font?.name, "Zed Mono")
        XCTAssertEqual(theme.font?.size, 16)
        XCTAssertEqual(try JSONDecoder().decode(LogTheme.self, from: JSONEncoder().encode(theme)), theme)
        XCTAssertThrowsError(try LogThemeImport.ghostty(defaults: "", current: "background = invalid"))
    }

    func testITermSelectsDefaultProfileAndImportsColorSpaceAndFont() throws {
        let rgb: [String: Any] = ["Red Component": 0.2, "Green Component": 0.4, "Blue Component": 0.6, "Color Space": "P3"]
        var profile: [String: Any] = ["Guid": "chosen", "Name": "Night", "Foreground Color": rgb, "Background Color": rgb, "Normal Font": "MesloLGS-Regular 15"]
        for index in 0..<16 { profile["Ansi \(index) Color"] = rgb }
        let preferences: [String: Any] = ["Default Bookmark Guid": "chosen", "New Bookmarks": [["Guid": "other"], profile]]
        let theme = try LogThemeImport.iTerm(preferences: preferences, dark: true)
        XCTAssertEqual(theme.name, "iTerm2 · Night")
        XCTAssertEqual(theme.palette[1]?.space, "P3")
        XCTAssertEqual(theme.font?.name, "MesloLGS-Regular")
        XCTAssertEqual(theme.font?.size, 15)
        XCTAssertThrowsError(try LogThemeImport.iTerm(preferences: [:], dark: true))
    }
}
