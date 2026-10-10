import Foundation

public struct TerminalColor: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public var space = "sRGB"

    public init(red: Double, green: Double, blue: Double, space: String = "sRGB") {
        self.red = red; self.green = green; self.blue = blue; self.space = space
    }
    public init?(hex: String) {
        let hex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

public struct TerminalFont: Codable, Equatable, Sendable {
    public let name: String
    public let size: Double
}

public struct LogTheme: Codable, Equatable, Sendable {
    public var name: String
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var selectionForeground: TerminalColor?
    public var selectionBackground: TerminalColor?
    public var palette: [Int: TerminalColor]
    public var font: TerminalFont?
}

public enum LogThemeImport {
    // Ghostty resolves named themes and included config files itself. Overlay its
    // current values on defaults because some versions only print changed values.
    public static func ghostty(defaults: String, current: String) throws -> LogTheme {
        var values: [String: String] = [:]
        var palette: [Int: TerminalColor] = [:]
        for line in (defaults + "\n" + current).split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            if pair[0] == "palette" {
                let entry = pair[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let index = Int(entry[0]), (0...255).contains(index), let color = TerminalColor(hex: entry[1]) {
                    palette[index] = color
                }
            } else { values[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        guard let fg = values["foreground"].flatMap(TerminalColor.init(hex:)),
              let bg = values["background"].flatMap(TerminalColor.init(hex:)),
              (0..<16).allSatisfy({ palette[$0] != nil }) else {
            throw LocalBarError("Ghostty didn't return a complete color palette.")
        }
        var font: TerminalFont?
        if let name = values["font-family"], !name.isEmpty, let size = values["font-size"].flatMap(Double.init), (6...72).contains(size) {
            font = TerminalFont(name: name, size: size)
        }
        return LogTheme(name: "Ghostty", foreground: fg, background: bg,
                        selectionForeground: values["selection-foreground"].flatMap(TerminalColor.init(hex:)),
                        selectionBackground: values["selection-background"].flatMap(TerminalColor.init(hex:)), palette: palette, font: font)
    }

    public static func iTerm(preferences: [String: Any], dark: Bool) throws -> LogTheme {
        guard let guid = preferences["Default Bookmark Guid"] as? String,
              let profiles = preferences["New Bookmarks"] as? [[String: Any]],
              let profile = profiles.first(where: { $0["Guid"] as? String == guid }) else {
            throw LocalBarError("Couldn't find iTerm2's saved default profile. Open iTerm2 and save a default profile, then try again.")
        }
        let separate = profile["Use Separate Colors for Light and Dark Mode"] as? Bool == true
        func color(_ name: String) -> TerminalColor? {
            let key = separate ? name + (dark ? " (Dark)" : " (Light)") : name
            guard let value = (profile[key] ?? profile[name]) as? [String: Any],
                  let red = value["Red Component"] as? Double,
                  let green = value["Green Component"] as? Double,
                  let blue = value["Blue Component"] as? Double,
                  [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            return TerminalColor(red: red, green: green, blue: blue, space: value["Color Space"] as? String ?? "Calibrated")
        }
        let palette = Dictionary(uniqueKeysWithValues: (0..<16).compactMap { index in color("Ansi \(index) Color").map { (index, $0) } })
        guard let fg = color("Foreground Color"), let bg = color("Background Color"), palette.count == 16 else {
            throw LocalBarError("iTerm2's default profile doesn't contain a complete color palette.")
        }
        var font: TerminalFont?
        if let description = profile["Normal Font"] as? String, let split = description.lastIndex(of: " "),
           let size = Double(description[description.index(after: split)...]), (6...72).contains(size) {
            font = TerminalFont(name: String(description[..<split]), size: size)
        }
        return LogTheme(name: "iTerm2 · \(profile["Name"] as? String ?? "Default")", foreground: fg, background: bg,
                        selectionForeground: color("Selected Text Color"), selectionBackground: color("Selection Color"), palette: palette, font: font)
    }
}
