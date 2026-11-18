import AppKit
import SwiftUI

/// Own settings window. The app is an agent app (LSUIElement) without a main menu, so the
/// SwiftUI `Settings` scene has no reliable way to open from AppKit.
final class SettingsWindowController {
    private let preferences: Preferences
    private let installer: HookInstaller
    private let remote: RemoteHub
    private let requestNotifications: () -> Void
    private var window: NSWindow?

    init(preferences: Preferences, installer: HookInstaller, remote: RemoteHub, requestNotifications: @escaping () -> Void) {
        self.preferences = preferences
        self.installer = installer
        self.remote = remote
        self.requestNotifications = requestNotifications
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                installer: installer,
                remote: remote,
                requestNotifications: requestNotifications
            )
        )
        // Fixed size: content-driven window resizing re-enters layout and aborts (NSWindow update-constraints exception).
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Agent Lounge Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        return window
    }
}
