import AppKit
import SwiftUI
import LocalBarCore

@MainActor final class Store: ObservableObject {
    @Published var services: [Service] = []
    @Published var snapshots: [String: Snapshot] = [:]
    @Published var busy: Set<String> = []
    @Published var errorMessage: String?
    @Published var configurationBusy = false
    @Published var configurationError: String?
    let paths: AppPaths
    let logPreview = LogPreviewController()
    let manager: Launchd
    let loginItem = LoginItem()
    let caddy: Caddy
    let caddyService: CaddyService
    @Published private(set) var caddyState = CaddyServiceStatus()
    @Published private(set) var caddyBusy = false
    @Published private(set) var caddyError: String?
    private var caddyChecked = false
    private var caddyRestarting = false
    private var routesPending = false
    private var revisions: [String: Int] = [:]
    private var lastCaddyCheck = Date.distantPast
    private var refreshing = false
    private var poller: Task<Void, Never>?
    private var editorWindow: NSWindow?
    private var logWindows: [String: NSWindow] = [:]
    private let configurationReader: ConfigurationReader
    private var appliedConfiguration: Configuration?
    private var configurationRevision = 0

    init(paths: AppPaths = AppPaths(), startMonitoring: Bool = true, caddy: Caddy? = nil) {
        self.paths = paths
        self.caddy = caddy ?? Caddy(paths: paths)
        caddyService = CaddyService(paths: paths)
        configurationReader = ConfigurationReader(file: paths.config)
        manager = Launchd(paths: paths)
        do { services = try paths.load().services } catch { configurationError = error.localizedDescription }
        guard startMonitoring else { return }
        poller = Task { [weak self] in
            if self?.configurationError == nil, self?.caddy.configured == true { await self?.runCaddy() }
            while !Task.isCancelled {
                await self?.reloadSavedConfiguration()
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { break }
            }
        }
    }

    deinit { poller?.cancel() }

    var groups: [String] { services.reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } } }
    var caddyStatus: String {
        if caddyBusy { return caddyRestarting ? "Restarting…" : "Starting…" }
        guard caddyChecked else { return "Checking" }
        return caddyState.available ? "Available" : "Unavailable"
    }
    var caddyDetail: String {
        if let caddyError { return caddyError }
        if !caddyState.available { return "Caddy is unavailable. Start it to use your local domains." }
        return caddyState.managed ? "Starts at boot and restarts automatically if it exits." : "Caddy is running outside Local Bar."
    }
    func startCaddy(restart: Bool = false) { Task { await runCaddy(restart: restart, interactive: true) } }
    private func runCaddy(restart: Bool = false, interactive: Bool = false) async {
        guard !caddyBusy, !configurationBusy else { return }
        caddyBusy = true; caddyRestarting = restart; caddyError = nil
        defer { caddyBusy = false }
        do {
            try await caddyService.start(services: services, restart: restart)
            routesPending = false
        } catch let error as CaddyInstallationRequired {
            caddyError = error.localizedDescription
            if interactive { openCaddySetup() }
        } catch { caddyError = error.localizedDescription }
        await checkCaddy()
    }
    private func checkCaddy() async {
        lastCaddyCheck = Date()
        caddyState = await caddyService.status()
        caddyChecked = true
        if routesPending && caddyState.available && !configurationBusy && !caddyBusy {
            configurationBusy = true
            defer { configurationBusy = false }
            do {
                routesPending = !(try await caddy.apply(services))
                caddyError = nil
            } catch { caddyError = error.localizedDescription }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if Date().timeIntervalSince(lastCaddyCheck) >= 15 {
            await checkCaddy()
            loginItem.refresh()
        }
        let revisionsAtStart = revisions
        let candidates = services.filter { !busy.contains($0.id) }
        let manager = manager
        await withTaskGroup(of: (String, Snapshot).self) { group in
            for service in candidates { group.addTask { (service.id, await Monitor.inspect(service, using: manager)) } }
            // Publish each result immediately; one slow server must not stall every row.
            for await (id, snapshot) in group where !busy.contains(id) && revisionsAtStart[id] == revisions[id] {
                if snapshots[id] != snapshot { snapshots[id] = snapshot }
            }
        }
    }

    func perform(_ action: Action, on service: Service) {
        guard !configurationBusy, !busy.contains(service.id) else { return }
        busy.insert(service.id)
        revisions[service.id, default: 0] += 1
        snapshots[service.id] = Snapshot(state: action.state, managed: action != .stop, detail: action.state.rawValue)
        Task {
            defer { busy.remove(service.id) }
            do {
                switch action {
                case .start: try await manager.start(service)
                case .stop: try await manager.stop(service)
                case .restart: try await manager.restart(service)
                }
                if action != .stop { try await waitUntilReady(service) }
            } catch { errorMessage = "\(service.group) · \(service.name)\n\n\(error.localizedDescription)" }
            snapshots[service.id] = await Monitor.inspect(service, using: manager)
        }
    }

    private func waitUntilReady(_ service: Service) async throws {
        let started = Date()
        while Date().timeIntervalSince(started) < service.startupTimeout {
            let snapshot = await Monitor.inspect(service, using: manager)
            if snapshot.state == .running { snapshots[service.id] = snapshot; return }
            if snapshot.state == .failed && Date().timeIntervalSince(started) > 2 { throw LocalBarError(snapshot.detail) }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LocalBarError("The server did not become ready within \(Int(service.startupTimeout)) seconds. It remains managed; check its logs or stop it here.")
    }

    func saveConfiguration(_ config: Configuration) async throws {
        try await applyConfiguration(config, writeToDisk: true)
    }

    private func applyConfiguration(_ config: Configuration, writeToDisk: Bool) async throws {
        guard !configurationBusy, !caddyBusy, busy.isEmpty else { throw LocalBarError("Wait for the current operation to finish.") }
        configurationBusy = true
        configurationRevision += 1
        defer { configurationBusy = false }
        try config.validate()
        for current in services where !config.services.contains(current) {
            if try await manager.job(current).loaded {
                throw LocalBarError("Stop \(current.group) \(current.name) before changing or removing it.")
            }
        }
        let previous = Configuration(services: services)
        let appliedRoutes = try await caddy.apply(config.services)
        do { if writeToDisk { try paths.write(config, to: paths.config) } }
        catch {
            let writeError = error
            do { try await caddy.apply(previous.services) }
            catch { throw LocalBarError("Could not save configuration or restore Caddy routes: \(writeError.localizedDescription)\n\(error.localizedDescription)") }
            throw writeError
        }
        routesPending = !appliedRoutes
        services = config.services
        appliedConfiguration = config
        for service in services { revisions[service.id, default: 0] += 1 }
        snapshots = snapshots.filter { id, _ in services.contains { $0.id == id } }
        configurationError = nil
        if writeToDisk { await refresh() }
    }

    func reloadSavedConfiguration() async {
        guard !configurationBusy, !caddyBusy, busy.isEmpty else { return }
        let revision = configurationRevision
        let config: Configuration
        do { config = try await configurationReader.read() }
        catch {
            guard revision == configurationRevision, !configurationBusy else { return }
            let message = "Saved changes were not applied. \(error.localizedDescription)"
            if configurationError != message { configurationError = message }
            return
        }
        guard revision == configurationRevision, !configurationBusy, !caddyBusy, busy.isEmpty else { return }
        guard config != appliedConfiguration else {
            if configurationError != nil { configurationError = nil }
            return
        }
        do { try await applyConfiguration(config, writeToDisk: false) }
        catch {
            let message = "Saved changes were not applied. \(error.localizedDescription)"
            if configurationError != message { configurationError = message }
        }
    }

    func showEditor(_ service: Service? = nil) {
        if editorWindow != nil { editorWindow?.close() }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = service == nil ? "Add server" : "Edit server"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ServiceEditor(store: self, service: service) { [weak window] in window?.close() })
        editorWindow = window
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func remove(_ service: Service) {
        Task {
            do { try await saveConfiguration(Configuration(services: services.filter { $0.id != service.id })) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func openConfiguration() {
        do {
            // A login shell reads EDITOR even when Finder launched the app without it.
            let script = paths.root.appendingPathComponent("edit-configuration.command")
            let quoted = "'" + paths.config.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let content = """
            #!/bin/zsh -il
            if [[ -z ${EDITOR:-} ]]; then
                print 'Set EDITOR in ~/.zshrc or ~/.zprofile, then try again.'
                exit 1
            fi
            editor=( ${(z)EDITOR} )
            exec "${(@Q)editor}" \(quoted)
            """
            try content.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw LocalBarError("Terminal is needed to run $EDITOR.")
            }
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch { errorMessage = error.localizedDescription }
    }
    private func openCaddySetup() {
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LocalBarSetup")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw LocalBarError("Run bash scripts/setup-caddy.sh from the Local Bar repo to install Caddy's background service.")
            }
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = paths.root.appendingPathComponent("setup-caddy.command")
            let command = "#!/bin/zsh\n/usr/bin/sudo \(quote(helper.path)) --install-service \(quote(paths.root.path))\n"
            try command.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw LocalBarError("Run bash scripts/setup-caddy.sh from the Local Bar repo to install Caddy's background service.")
            }
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch { caddyError = error.localizedDescription }
    }
    func showCaddyLogs() {
        let service = Service(id: "caddy", group: "Local Bar", name: "Caddy", directory: paths.root.path,
                              executable: "/usr/bin/true", arguments: [], url: "http://localhost", port: 80)
        showLogs(service, title: "Caddy · Logs")
    }
    func showLogs(_ service: Service, title: String? = nil) {
        if let window = logWindows[service.id] {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = LogWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title ?? "\(service.group) · \(service.name) · Logs"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LogsView(service: service, paths: paths))
        window.center(); window.makeKeyAndOrderFront(nil)
        logWindows[service.id] = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum Action {
    case start, stop, restart
    var state: ServiceState { switch self { case .start: return .starting; case .stop: return .stopping; case .restart: return .restarting } }
}
