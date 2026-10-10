import SwiftUI
import AppKit
import LocalBarCore

private struct LogAppearanceSettings: Codable, Equatable {
    var imported: LogTheme?
    var useImported = false
    var fontSizeAdjustment: Double?
}

@MainActor final class LogAppearance: ObservableObject {
    static let shared = LogAppearance()
    @Published private var settings: LogAppearanceSettings {
        didSet { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "logAppearance") } }
    }
    @Published var importing = false
    @Published var error: String?
    var imported: LogTheme? { settings.imported }
    var theme: LogTheme? { settings.useImported ? settings.imported : nil }
    private var selectedFont: NSFont? {
        guard let font = theme?.font else { return nil }
        return NSFont(name: font.name, size: font.size)
            ?? NSFontManager.shared.font(withFamily: font.name, traits: [], weight: 5, size: font.size)
            ?? .monospacedSystemFont(ofSize: font.size, weight: .regular)
    }
    private var viewerBaseFont: NSFont { selectedFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular) }
    var viewerFont: NSFont {
        resized(viewerBaseFont, to: viewerBaseFont.pointSize + (settings.fontSizeAdjustment ?? 0))
    }
    var previewFont: NSFont {
        let font = selectedFont ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        return resized(font, to: font.pointSize - 1)
    }
    func changeFontSize(by points: Double) {
        let size = min(72, max(6, viewerFont.pointSize + points))
        settings.fontSizeAdjustment = size - viewerBaseFont.pointSize
    }
    func resetFontSize() { settings.fontSizeAdjustment = nil }
    private func resized(_ font: NSFont, to size: Double) -> NSFont {
        NSFontManager.shared.convert(font, toSize: min(72, max(6, size)))
    }

    private init() {
        settings = UserDefaults.standard.data(forKey: "logAppearance")
            .flatMap { try? JSONDecoder().decode(LogAppearanceSettings.self, from: $0) } ?? LogAppearanceSettings()
    }
    func selectImported(_ value: Bool) {
        settings = LogAppearanceSettings(imported: settings.imported, useImported: value)
    }

    func importGhostty() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
            error = "Ghostty isn't installed."; return
        }
        let executable = app.appendingPathComponent("Contents/MacOS/ghostty").path
        runImport {
            let defaults = try await Commands.run(executable, ["+show-config", "--default"])
            let current = try await Commands.run(executable, ["+show-config"])
            guard defaults.status == 0, current.status == 0 else { throw LocalBarError("Couldn't read Ghostty's configuration.") }
            return try LogThemeImport.ghostty(defaults: defaults.output, current: current.output)
        }
    }
    func importITerm() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        runImport {
            try await Task.detached(priority: .utility) {
                let domain = "com.googlecode.iterm2"
                var preferences = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
                if preferences["LoadPrefsFromCustomFolder"] as? Bool == true,
                   let folder = preferences["PrefsCustomFolder"] as? String {
                    let path = (folder as NSString).expandingTildeInPath
                    guard path.hasPrefix("/") else { throw LocalBarError("Importing iTerm2 settings from a remote URL isn't supported.") }
                    let file = URL(fileURLWithPath: path).appendingPathComponent("\(domain).plist")
                    preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] ?? [:]
                }
                return try LogThemeImport.iTerm(preferences: preferences, dark: dark)
            }.value
        }
    }
    private func runImport(_ operation: @escaping () async throws -> LogTheme) {
        guard !importing else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let theme = try await operation()
                settings = LogAppearanceSettings(imported: theme, useImported: true)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct LogAppearanceMenu: View {
    @ObservedObject private var appearance = LogAppearance.shared
    var body: some View {
        Menu {
            Button { appearance.selectImported(false) } label: {
                if appearance.theme == nil { Label("System", systemImage: "checkmark") } else { Text("System") }
            }
            if let imported = appearance.imported {
                Button { appearance.selectImported(true) } label: {
                    if appearance.theme != nil { Label(imported.name, systemImage: "checkmark") } else { Text(imported.name) }
                }
            }
            Menu("Import from…") {
                Button("Ghostty") { appearance.importGhostty() }
                Button("iTerm2") { appearance.importITerm() }
            }
            Divider()
            Button("Larger text") { appearance.changeFontSize(by: 1) }.keyboardShortcut("+")
                .disabled(appearance.viewerFont.pointSize >= 72)
            Button("Smaller text") { appearance.changeFontSize(by: -1) }.keyboardShortcut("-")
                .disabled(appearance.viewerFont.pointSize <= 6)
            Button("Reset text size") { appearance.resetFontSize() }.keyboardShortcut("0")
        } label: { Label("Log appearance", systemImage: "paintpalette") }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(appearance.importing)
        .help("\(appearance.theme?.name ?? "System") colors, font, and size. Applies to all log windows.")
        .alert("Log appearance", isPresented: Binding(get: { appearance.error != nil }, set: { if !$0 { appearance.error = nil } })) {
            Button("OK", role: .cancel) { appearance.error = nil }
        } message: { Text(appearance.error ?? "") }
    }
}

extension TerminalColor {
    var nsColor: NSColor {
        switch space {
        case "P3": return NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1)
        case "Calibrated": return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        default: return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }
}
