import SwiftUI
import AppKit
import LocalBarCore

struct LogsView: View {
    let service: Service
    let paths: AppPaths
    @State private var content = LogContent(text: "Loading…")
    @State private var follow = true
    @ObservedObject private var appearance = LogAppearance.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                LogAppearanceMenu()
                Spacer()
                Toggle("Live updates", isOn: $follow).toggleStyle(.checkbox)
                CopyLogCommandButton(service: service, paths: paths)
                Button("Open log file") { NSWorkspace.shared.open(paths.log(service)) }
            }.padding(12)
            Divider()
            NativeLogText(content: content, theme: appearance.theme, font: appearance.font)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            let reader = LogReader()
            while !Task.isCancelled {
                if follow || content.text == "Loading…" {
                    let next = await reader.read(paths.log(service))
                    if !Task.isCancelled && next != content { content = next }
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
    }
}

struct CopyLogCommandButton: View {
    let service: Service
    let paths: AppPaths
    var external = false
    @State private var copied = false
    private var available: Bool { !external && FileManager.default.fileExists(atPath: paths.log(service).path) }

    var body: some View {
        Button(copied ? "Copied!" : "Copy logs tail command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(LogCommand.follow(paths.log(service)), forType: .string)
            copied = true
        }
        .disabled(!available)
        .help(available ? "Paste into your terminal to follow recent output." : "Start this server in Local Bar to capture logs.")
        .task(id: copied) {
            if copied {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                copied = false
            }
        }
    }
}
