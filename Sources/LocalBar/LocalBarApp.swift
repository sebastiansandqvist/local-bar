import SwiftUI
import AppKit
import LocalBarCore

@main struct LocalBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MartiniIcon.image()
            button.image?.isTemplate = true
            button.toolTip = "Local Bar"
            button.target = self
            button.action = #selector(toggleMenu)
        }
        statusItem = item
        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: MenuView(store: store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        showMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenu()
        return false
    }

    @objc private func toggleMenu() {
        if popover.isShown { popover.performClose(nil) } else { showMenu() }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

struct MenuView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Local Bar").font(.system(size: 13, weight: .medium))
                Spacer()
                Menu {
                    Button("Add server…") { store.showEditor() }
                    Divider()
                    Button("Edit configuration…") { store.openConfiguration() }
                    Button("Reload configuration") { store.reloadConfiguration() }.disabled(!store.busy.isEmpty || store.configurationBusy)
                    Button("Open logs folder") { NSWorkspace.shared.open(store.paths.logs) }
                    Divider()
                    Button("Quit Local Bar") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Configuration, logs, and quit. Servers keep running when you quit.")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if let error = store.configurationError {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Configuration needs attention").fontWeight(.medium)
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Edit configuration…") { store.openConfiguration() }
                    Button("Reload") { store.reloadConfiguration() }
                }.padding(16)
            } else {
                if store.services.isEmpty {
                    VStack(spacing: 10) {
                        Text("Add your first local server").foregroundStyle(.secondary)
                        Button("Add server…") { store.showEditor() }
                    }.padding(24)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.groups, id: \.self) { group in
                            Text(group).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 3)
                            ForEach(store.services.filter { $0.group == group }) { service in
                                ServiceRow(service: service, store: store)
                            }
                        }
                    }.padding(.bottom, 10)
                }.scrollIndicators(.hidden)
                    .frame(height: min(CGFloat(store.services.count * 49 + store.groups.count * 28 + 10), 520))
            }
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "network").font(.system(size: 12))
                Text("Caddy")
                Spacer()
                Circle().fill(store.caddyStatus == "Available" ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(store.caddyStatus).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 12).help(store.caddyDetail)
        }
        .frame(width: 410)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Local Bar", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct ServiceRow: View {
    let service: Service
    @ObservedObject var store: Store
    @State private var hovered = false
    private var snapshot: Snapshot { store.snapshots[service.id] ?? Snapshot() }
    private var busy: Bool { store.configurationBusy || store.busy.contains(service.id) }
    private var color: Color {
        if snapshot.routeWarning { return .orange }
        switch snapshot.state {
        case .running: return .green
        case .failed, .unresponsive: return .red
        case .external, .starting, .stopping, .restarting: return .orange
        default: return .secondary
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(service.name).font(.system(size: 13)).lineLimit(1)
                }
                Button {
                    if let url = URL(string: service.url) { NSWorkspace.shared.open(url) }
                } label: {
                    Text(URL(string: service.url)?.host ?? service.url)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.buttonStyle(.plain).padding(.leading, 13).help("Open \(service.url) · port \(service.port)")
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(snapshot.state.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing).help(snapshot.detail)
                .accessibilityLabel("\(service.name): \(snapshot.state.rawValue). \(snapshot.detail)")
            Button { store.perform(.restart, on: service) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 24, height: 28)
            }.buttonStyle(.plain).disabled(busy || !snapshot.managed)
                .help("Restart \(service.name)").accessibilityLabel("Restart \(service.group) \(service.name)")
            Toggle("\(service.group) \(service.name)", isOn: Binding(
                get: { snapshot.managed || snapshot.state == .external },
                set: { store.perform($0 ? .start : .stop, on: service) }
            ))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden().frame(width: 32)
            .disabled(busy || [.external, .checking, .unknown].contains(snapshot.state))
            .help(snapshot.state == .external ? snapshot.detail : snapshot.managed ? "Stop \(service.name)" : "Start \(service.name)")
        }
        .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 9)
        .background(hovered ? Color.primary.opacity(0.045) : Color.clear)
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .contextMenu {
            Button("Open in browser") { if let url = URL(string: service.url) { NSWorkspace.shared.open(url) } }
            Button("Show logs…") { store.showLogs(service) }
            CopyLogCommandButton(service: service, paths: store.paths, external: snapshot.state == .external)
            Button("Open project folder") { NSWorkspace.shared.open(service.folder) }
            Button("Copy address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(service.url, forType: .string) }
            Divider()
            Button("Edit server…") { store.showEditor(service) }.disabled(busy)
            Button("Remove server", role: .destructive) { store.remove(service) }.disabled(busy || snapshot.managed)
            Divider()
            Button("Service details…") { store.errorMessage = "\(service.group) · \(service.name)\nPort \(service.port)\(snapshot.pid.map { " · PID \($0)" } ?? "")\n\n\(snapshot.detail)" }
        }
    }
}
