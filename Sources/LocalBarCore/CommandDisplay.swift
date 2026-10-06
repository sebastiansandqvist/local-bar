import Foundation

public enum CommandDisplay {
    public static func text(for service: Service) -> String {
        if service.executable == "/bin/zsh", service.arguments.count == 2, service.arguments[0] == "-c" {
            return service.arguments[1]
        }
        var executable = service.executablePath
        let name = URL(fileURLWithPath: executable).lastPathComponent
        // Only shorten common runtime commands, not shell built-ins or reserved words.
        let runtimes: Set<String> = ["bun", "node", "npm", "npx", "pnpm", "yarn", "deno", "python", "python3", "ruby", "go", "cargo"]
        if runtimes.contains(name), let path = service.environment["PATH"] {
            for entry in path.components(separatedBy: ":") {
                let directory = entry.hasPrefix("/") ? URL(fileURLWithPath: entry) : service.folder.appendingPathComponent(entry)
                let candidate = directory.appendingPathComponent(name)
                guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
                if candidate.resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL {
                    executable = name
                }
                break
            }
        }
        return ([executable] + service.arguments).map(quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        if !value.isEmpty, value.range(of: "^[a-zA-Z0-9_./:@%+=,-]+$", options: .regularExpression) != nil { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
