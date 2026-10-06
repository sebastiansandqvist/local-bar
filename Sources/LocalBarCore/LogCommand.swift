import Foundation

public enum LogCommand {
    public static func follow(_ file: URL) -> String {
        // Single quotes protect spaces, quotes, and shell substitutions in the path.
        let path = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "/usr/bin/printf '%s\\n' 'Ctrl+C to stop following logs without stopping the server'; /usr/bin/tail -n 100 -F \(path)"
    }
}
