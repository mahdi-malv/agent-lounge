import os
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (PLAN §6). macOS owns the state.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user must allow the login item in System Settings > General > Login Items.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Returns an error text on failure.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Settings")
                .error("Launch at login: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
