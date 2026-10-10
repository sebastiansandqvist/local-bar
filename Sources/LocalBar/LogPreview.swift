import SwiftUI
import AppKit
import LocalBarCore

private final class LogPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class LogPreviewContent: ObservableObject {
    @Published var log = LogContent(text: "Loading…")
}

@MainActor final class LogPreviewController {
    private weak var menuWindow: NSWindow?
    private let anchors = NSHashTable<LogPreviewAnchorView>.weakObjects()
    private var monitor: Any?
    private var deactivation: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var panel: LogPreviewPanel?
    private var content: LogPreviewContent?
    private var currentID: String?
    private var pointer: NSPoint?
    private var suppressed = false
    private var side: LogPreviewPlacement.Side?
    private var previousMouseMovedEvents = false

    func start(in window: NSWindow) {
        stop()
        menuWindow = window
        previousMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        side = nil
        pointer = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseDragged, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .mouseMoved, .mouseEntered, .mouseExited:
                guard event.window === self.menuWindow || event.type == .mouseMoved else { return event }
                self.suppressed = false
                self.pointer = event.window === self.menuWindow ? event.locationInWindow : nil
                self.refresh()
            case .scrollWheel:
                self.pointer = event.window === self.menuWindow ? event.locationInWindow : nil
                // Re-evaluate after the scroll view has moved its rows.
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            default:
                self.suppressed = true
                self.dismiss()
            }
            return event
        }
        deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        refresh()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
        monitor = nil; deactivation = nil
        dismiss()
        menuWindow?.acceptsMouseMovedEvents = previousMouseMovedEvents
        menuWindow = nil
        pointer = nil
        suppressed = false
    }

    func register(_ anchor: LogPreviewAnchorView) { anchors.add(anchor) }
    func unregister(_ anchor: LogPreviewAnchorView) { anchors.remove(anchor); refresh() }

    func refresh() {
        guard !suppressed, let window = menuWindow, window.isVisible else { dismiss(); return }
        let point = pointer ?? window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let anchor = anchor(at: point, in: window), anchor.state.canPreviewLogs,
              let service = anchor.service, let log = anchor.log else { dismiss(); return }
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? window.frame
        let side = self.side ?? LogPreviewPlacement.side(menu: window.frame, screen: screen, width: 420)
        self.side = side
        let font = LogAppearance.shared.previewFont
        let content = currentID == service.id ? self.content ?? LogPreviewContent() : LogPreviewContent()
        let height = NativeLogText.previewHeight(for: content.log, font: font)
        let frame = LogPreviewPlacement.frame(row: row, menu: window.frame, screen: screen,
                                              size: NSSize(width: 420, height: height), side: side)
        if currentID == service.id, let panel {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            return
        }
        dismiss()
        currentID = service.id
        self.content = content
        let preview = LogPreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        preview.backgroundColor = .clear
        preview.isOpaque = false
        preview.hasShadow = true
        preview.ignoresMouseEvents = true
        preview.hidesOnDeactivate = true
        preview.contentViewController = NSHostingController(rootView: LogPreviewView(content: content))
        preview.setFrame(frame, display: false)
        panel = preview
        window.addChildWindow(preview, ordered: .above)
        preview.orderFront(nil)
        // No hover delay or prefetching. Read a small tail only while the preview is visible.
        task = Task { [weak self] in
            let maximumLines = max(1, min(10, Int((320 - 2 * NativeLogText.inset.height) / NativeLogText.previewLineHeight(for: font))))
            let reader = LogReader(maximumBytes: 16_384, maximumLines: maximumLines, emptyMessage: "Waiting for output…")
            while !Task.isCancelled {
                let next = await reader.read(log).removingTrailingNewline()
                guard !Task.isCancelled, self?.currentID == service.id else { return }
                if content.log != next { content.log = next; self?.refresh() }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    private func anchor(at point: NSPoint, in window: NSWindow) -> LogPreviewAnchorView? {
        anchors.allObjects.first {
            // A non-clipping NSView's visibleRect can extend beyond the row itself.
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.intersection($0.visibleRect).contains($0.convert(point, from: nil))
        }
    }

    private func dismiss() {
        task?.cancel(); task = nil
        currentID = nil
        content = nil
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
        panel = nil
    }
}

struct LogPreviewAnchor: NSViewRepresentable {
    let controller: LogPreviewController
    let service: Service
    let state: ServiceState
    let log: URL
    func makeNSView(context: Context) -> LogPreviewAnchorView {
        let view = LogPreviewAnchorView()
        view.controller = controller
        controller.register(view)
        return view
    }
    func updateNSView(_ view: LogPreviewAnchorView, context: Context) {
        view.service = service; view.state = state; view.log = log
        controller.refresh()
    }
    static func dismantleNSView(_ view: LogPreviewAnchorView, coordinator: ()) { view.controller?.unregister(view) }
}

final class LogPreviewAnchorView: NSView {
    weak var controller: LogPreviewController?
    var service: Service?
    var state: ServiceState = .off
    var log: URL?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct LogPreviewView: View {
    @ObservedObject var content: LogPreviewContent
    @ObservedObject private var appearance = LogAppearance.shared
    var body: some View {
        NativeLogText(content: content.log, theme: appearance.theme, font: appearance.previewFont, preview: true)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .allowsHitTesting(false)
    }
}
