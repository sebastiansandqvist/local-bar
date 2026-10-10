import Foundation

public enum ANSIColor: Equatable, Hashable, Sendable {
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
}

public struct ANSIStyle: Equatable, Hashable, Sendable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strikethrough = false
}

public struct LogRun: Equatable, Sendable {
    public let range: NSRange
    public let style: ANSIStyle
}

public struct LogContent: Equatable, Sendable {
    public let text: String
    public let runs: [LogRun]
    public init(text: String, runs: [LogRun] = []) { self.text = text; self.runs = runs }

    // A final line terminator is not an extra empty row in the compact preview.
    public func removingTrailingNewline() -> LogContent {
        guard text.hasSuffix("\n") else { return self }
        let trimmed = String(text.dropLast())
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        let clipped = runs.compactMap { run -> LogRun? in
            let intersection = NSIntersectionRange(run.range, range)
            return intersection.length > 0 ? LogRun(range: intersection, style: run.style) : nil
        }
        return LogContent(text: trimmed, runs: clipped)
    }
}

// Interpret text styling only. Other terminal commands never reach the text view.
public enum ANSILog {
    public static func parse(_ raw: String, maximumLines: Int = 2000) -> LogContent {
        let input = Array(raw.unicodeScalars)
        var text = String.UnicodeScalarView()
        var runs: [LogRun] = []
        var style = ANSIStyle()
        var length = 0, runStart = 0, i = 0
        func flush() {
            if length > runStart, style != ANSIStyle() {
                runs.append(LogRun(range: NSRange(location: runStart, length: length - runStart), style: style))
            }
            runStart = length
        }
        while i < input.count {
            let code = input[i].value
            if code == 0x1b {
                i += 1
                guard i < input.count else { break }
                let kind = input[i].value
                i += 1
                if kind == 0x5b { // CSI, including SGR color/style sequences.
                    let start = i
                    while i < input.count, !(0x40...0x7e).contains(input[i].value) { i += 1 }
                    if i < input.count, input[i] == "m" {
                        flush()
                        apply(String(String.UnicodeScalarView(input[start..<i])), to: &style)
                    }
                    i = min(i + 1, input.count)
                } else if [0x5d, 0x50, 0x58, 0x5e, 0x5f].contains(kind) { // OSC/DCS and other control strings.
                    while i < input.count {
                        if input[i].value == 7 || input[i].value == 0x9c { i += 1; break }
                        if input[i].value == 0x1b, i + 1 < input.count, input[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
                } else if (0x20...0x2f).contains(kind) {
                    while i < input.count, (0x20...0x2f).contains(input[i].value) { i += 1 }
                    i = min(i + 1, input.count)
                }
                continue
            }
            if code == 13 {
                // Keep progress output as log lines, without duplicating CRLF newlines.
                if i + 1 == input.count || input[i + 1] != "\n" { text.append("\n"); length += 1 }
            } else if code == 9 || code == 10 || (code >= 32 && !(0x7f...0x9f).contains(code)) {
                text.append(input[i]); length += code > 0xffff ? 2 : 1
            }
            i += 1
        }
        flush()
        let full = String(text)
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maximumLines else { return LogContent(text: full, runs: runs) }
        let clipped = lines.suffix(maximumLines).joined(separator: "\n")
        let removed = full.utf16.count - clipped.utf16.count
        let clippedRuns = runs.compactMap { run -> LogRun? in
            let start = max(run.range.location, removed)
            let end = NSMaxRange(run.range)
            guard end > start else { return nil }
            return LogRun(range: NSRange(location: start - removed, length: end - start), style: run.style)
        }
        return LogContent(text: clipped, runs: clippedRuns)
    }

    private static func apply(_ parameters: String, to style: inout ANSIStyle) {
        let groups = parameters.components(separatedBy: ";")
        var i = 0
        while i < groups.count {
            let parts = groups[i].components(separatedBy: ":")
            let code = parts[0].isEmpty ? 0 : Int(parts[0]) ?? -1
            i += 1
            if code == 38 || code == 48 {
                var values: [Int?]
                if parts.count > 1 { values = parts.dropFirst().map(Int.init) }
                else {
                    guard i < groups.count else { break }
                    let count = groups[i] == "5" ? 2 : groups[i] == "2" ? 4 : 1
                    values = groups[i..<min(i + count, groups.count)].map(Int.init)
                    i += values.count
                }
                var color: ANSIColor?
                if values.count == 2, values[0] == 5, let index = values[1], (0...255).contains(index) {
                    color = .indexed(index)
                } else if values.first == 2 {
                    // Colon syntax may include an empty/default color-space slot.
                    if values.count == 5, values[1] == nil || values[1] == 0 { values.remove(at: 1) }
                    if values.count == 4, let r = values[1], let g = values[2], let b = values[3],
                       [r, g, b].allSatisfy({ (0...255).contains($0) }) { color = .rgb(UInt8(r), UInt8(g), UInt8(b)) }
                }
                if let color { if code == 38 { style.foreground = color } else { style.background = color } }
                continue
            }
            switch code {
            case 0: style = ANSIStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = parts.count == 1 || parts[1] != "0"
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .indexed(code - 30)
            case 39: style.foreground = nil
            case 40...47: style.background = .indexed(code - 40)
            case 49: style.background = nil
            case 90...97: style.foreground = .indexed(code - 90 + 8)
            case 100...107: style.background = .indexed(code - 100 + 8)
            default: break
            }
        }
    }
}
