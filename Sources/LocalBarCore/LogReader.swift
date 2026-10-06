import Foundation

// File I/O and ANSI cleanup run off the main actor. Bound both bytes and lines.
public actor LogReader {
    public init() {}
    public func read(_ url: URL) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            return "No log yet. Start this service through Local Bar to capture its output."
        }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            let offset = size > 100_000 ? size - 100_000 : 0
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: 100_000) ?? Data()
            var raw = String(decoding: data, as: UTF8.self)
            if offset > 0, let newline = raw.firstIndex(of: "\n") { raw = String(raw[raw.index(after: newline)...]) }
            raw = raw.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            return raw.components(separatedBy: "\n").suffix(2000).joined(separator: "\n")
        } catch { return error.localizedDescription }
    }
}
