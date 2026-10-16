import AppKit
import ServiceManagement
import SwiftUI

@MainActor final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published var error: String?
    var enabled: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = error.localizedDescription }
        refresh()
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
