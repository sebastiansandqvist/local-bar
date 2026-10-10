import Foundation

// File I/O and ANSI parsing run off the main actor. Bound both bytes and lines.
public actor LogReader {
    private var lastRaw: String?
    private var lastContent = LogContent(text: "")
    private let maximumBytes: Int
    private let maximumLines: Int
    private let emptyMessage: String
    public init(maximumBytes: Int = 100_000, maximumLines: Int = 2000,
                emptyMessage: String = "No log yet. Start this service through Local Bar to capture its output.") {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumLines = max(1, maximumLines)
        self.emptyMessage = emptyMessage
    }
    public func read(_ url: URL) -> LogContent {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            return LogContent(text: emptyMessage)
        }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            let offset = size > maximumBytes ? size - UInt64(maximumBytes) : 0
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: maximumBytes) ?? Data()
            var raw = String(decoding: data, as: UTF8.self)
            if offset > 0, let newline = raw.firstIndex(of: "\n") { raw = String(raw[raw.index(after: newline)...]) }
            if raw != lastRaw { lastContent = ANSILog.parse(raw, maximumLines: maximumLines); lastRaw = raw }
            return lastContent.text.isEmpty ? LogContent(text: emptyMessage) : lastContent
        } catch { return LogContent(text: error.localizedDescription) }
    }
}
