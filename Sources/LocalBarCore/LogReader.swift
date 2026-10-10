import Foundation

// File I/O and ANSI parsing run off the main actor. Bound both bytes and lines.
public actor LogReader {
    private var lastRaw: String?
    private var lastContent = LogContent(text: "")
    public init() {}
    public func read(_ url: URL) -> LogContent {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            return LogContent(text: "No log yet. Start this service through Local Bar to capture its output.")
        }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            let offset = size > 100_000 ? size - 100_000 : 0
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: 100_000) ?? Data()
            var raw = String(decoding: data, as: UTF8.self)
            if offset > 0, let newline = raw.firstIndex(of: "\n") { raw = String(raw[raw.index(after: newline)...]) }
            if raw != lastRaw { lastContent = ANSILog.parse(raw); lastRaw = raw }
            return lastContent
        } catch { return LogContent(text: error.localizedDescription) }
    }
}
