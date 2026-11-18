import AppKit
import os

/// Brings a session's window to the front (PLAN M4). Never changes or stops the agent.
final class FocusService {
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Focus")
    /// Ask for Accessibility at most once per launch; the system prompt is noisy.
    private var askedForAccessibility = false

    func focus(_ session: AgentSession) {
        let route = FocusRoute.route(for: session)
        logger.info("Focus \(session.id, privacy: .public) via \(String(describing: route), privacy: .public)")
        switch route {
        case .ghostty(let tty):
            if focusGhostty(tty: tty) { return }
            activateHostApp(of: session)
        case .claudeApp(let appSessionId):
            if let url = FocusRoute.claudeAppURL(appSessionId: appSessionId), NSWorkspace.shared.open(url) { return }
            activateHostApp(of: session)
        case .codexApp(let threadId):
            if let url = FocusRoute.codexAppURL(threadId: threadId), NSWorkspace.shared.open(url) { return }
            activateHostApp(of: session)
        case .zed(let names):
            activateHostApp(of: session, preferredWindowNames: names)
        case .app:
            activateHostApp(of: session)
        }
    }

    // MARK: - Ghostty

    /// Ghostty 1.3+ AppleScript. Needs the Automation permission (asked by macOS on first use).
    private func focusGhostty(tty: String) -> Bool {
        guard tty.range(of: #"^/dev/tty[a-z0-9]+$"#, options: .regularExpression) != nil else { return false }
        let source = """
        tell application id "\(FocusRoute.ghosttyBundleId)"
            focus (first terminal whose tty is "\(tty)")
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? ""
            logger.error("Ghostty focus failed (\(number)): \(message, privacy: .public)")
            return false
        }
        return true
    }

    // MARK: - Generic

    /// Activate the app that hosts the agent. With Accessibility: raise the matching window
    /// (or restore a minimized one) and make the app frontmost.
    private func activateHostApp(of session: AgentSession, preferredWindowNames: [String] = []) {
        guard let app = hostApplication(of: session) else {
            logger.error("No host app for \(session.id, privacy: .public)")
            return
        }
        app.unhide()

        guard AccessibilityWindows.isTrusted else {
            requestAccessibilityOnce()
            app.activate()
            return
        }

        let windows = AccessibilityWindows.windows(of: app.processIdentifier)
        let titles = windows.map(AccessibilityWindows.title(of:))
        if let index = FocusRoute.bestWindowIndex(titles: titles, names: preferredWindowNames) {
            AccessibilityWindows.raise(windows[index])
        } else if !windows.isEmpty, windows.allSatisfy(AccessibilityWindows.isMinimized) {
            AccessibilityWindows.raise(windows[0])
        }
        if !AccessibilityWindows.setFrontmost(app.processIdentifier) {
            app.activate()
        }
    }

    /// First GUI app in the agent's ancestor chain (e.g. claude → zsh → login → Ghostty).
    private func hostApplication(of session: AgentSession) -> NSRunningApplication? {
        var chain: [ProcessEntry] = []
        if let pid = session.pid, ProcessInspector.isAlive(pid, startTime: session.pidStartTime) {
            chain = ProcessInspector.ancestry(from: pid)
        }
        if chain.isEmpty { chain = session.hostInfo?.processes ?? [] }
        for entry in chain where entry.pid > 1 {
            if let app = NSRunningApplication(processIdentifier: entry.pid), app.activationPolicy != .prohibited {
                return app
            }
        }
        if let bundleId = session.hostInfo?.bundleId {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        }
        return nil
    }

    private func requestAccessibilityOnce() {
        guard !askedForAccessibility else { return }
        askedForAccessibility = true
        AccessibilityWindows.requestTrust()
    }
}
