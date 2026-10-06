import AppKit
import SwiftUI
import LocalBarCore

struct ServiceEditor: View {
    @ObservedObject var store: Store
    let original: Service?
    let close: () -> Void
    @State private var name: String
    @State private var group: String
    @State private var folder: String
    @State private var command: String
    @State private var domain: String
    @State private var port: String
    @State private var error: String?
    @State private var saving = false

    init(store: Store, service: Service?, close: @escaping () -> Void) {
        self.store = store; self.original = service; self.close = close
        _name = State(initialValue: service?.name ?? "")
        _group = State(initialValue: service?.group ?? "Local")
        _folder = State(initialValue: service?.directory ?? "")
        _command = State(initialValue: service.map { CommandDisplay.text(for: $0) } ?? "npm run dev")
        _domain = State(initialValue: service.flatMap { URL(string: $0.url)?.host } ?? "")
        _port = State(initialValue: service.map { String($0.port) } ?? "3000")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Name", text: $name)
                TextField("Group", text: $group)
                HStack {
                    TextField("Project folder", text: $folder)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                }
                TextField("Start command", text: $command, prompt: Text("bun run dev"))
                    .help("For example: bun dev, npm run dev, or pnpm dev. Full executable paths are optional when the command is on PATH.")
                TextField("Port", text: $port)
                TextField("Domain", text: $domain, prompt: Text("my-app.localhost"))
            }
            Text("Use the same port in your server's command or project settings. Commands run in the project folder.").font(.caption).foregroundStyle(.secondary)
            if !Caddy(paths: store.paths).configured {
                Text("Domains need the one-time Caddy setup described in the README.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { save() }.keyboardShortcut(.defaultAction).disabled(saving || store.configurationBusy)
            }
        }.padding(20).frame(width: 500)
    }
    private func save() {
        saving = true
        Task { @MainActor in
            do {
                guard let number = Int(port), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalBarError("Enter a port and start command.") }
                let url = domain.hasPrefix("http://") ? domain : "http://\(domain)"
                _ = try Caddy.domain(url)
                let directory = (folder as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw LocalBarError("Choose an existing project folder.") }
                var environment = original?.environment ?? [:]
                if environment["PATH"] == nil { environment["PATH"] = Configuration.runtimePath() }
                let unchangedCommand = original.map { CommandDisplay.text(for: $0) == command } ?? false
                let service = Service(id: original?.id ?? UUID().uuidString.lowercased(),
                    group: group.trimmingCharacters(in: .whitespaces).isEmpty ? "Local" : group,
                    name: name.trimmingCharacters(in: .whitespaces), directory: directory,
                    executable: unchangedCommand ? original!.executable : "/bin/zsh",
                    arguments: unchangedCommand ? original!.arguments : ["-c", command], environment: environment,
                    url: url, port: number, healthPath: original?.healthPath, startupTimeout: original?.startupTimeout ?? 30)
                var next = store.services
                if let index = next.firstIndex(where: { $0.id == service.id }) { next[index] = service } else { next.append(service) }
                try await store.saveConfiguration(Configuration(services: next))
                close()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
