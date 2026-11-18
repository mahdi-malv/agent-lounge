import SwiftUI

@main
struct AgentLoungeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The real UI is the status item + panel (AppDelegate). Settings use their own window
        // (`SettingsWindowController`): an LSUIElement app has no menu to open this scene.
        Settings {
            EmptyView()
        }
    }
}
