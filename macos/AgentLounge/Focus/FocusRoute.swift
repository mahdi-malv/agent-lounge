import Foundation

/// How to bring a session's window to the front (PLAN D9). Pure, so it can be unit tested.
nonisolated enum FocusRoute: Equatable, Sendable {
    /// Ghostty AppleScript: `focus` the terminal with this tty (also restores a minimized window).
    case ghostty(tty: String)
    /// Claude.app deep link `claude://code/continue?session=<local_…>`.
    case claudeApp(appSessionId: String)
    /// Codex app deep link `codex://threads/<thread id>`.
    case codexApp(threadId: String)
    /// Zed: raise the window whose title matches one of these names (AX).
    case zed(windowNames: [String])
    /// Activate the parent app and restore a minimized window (AX).
    case app

    static let ghosttyBundleId = "com.mitchellh.ghostty"

    static func route(for session: AgentSession) -> FocusRoute {
        let host = session.hostInfo
        if let id = session.appSessionId, id.hasPrefix("local_") {
            return .claudeApp(appSessionId: id)
        }
        if session.agent == .codex, session.host == .codexApp, let id = session.agentSessionId, !id.isEmpty {
            return .codexApp(threadId: id)
        }
        if session.host == .terminal("Ghostty"), let tty = host?.tty {
            return .ghostty(tty: tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)")
        }
        if session.host == .zed {
            return .zed(windowNames: zedWindowNames(for: session))
        }
        return .app
    }

    /// Zed titles a window after its project folder. Launch folder first, then the current folder.
    static func zedWindowNames(for session: AgentSession) -> [String] {
        var names: [String] = []
        for path in [session.projectDirectory, session.cwd] {
            guard let path, !path.isEmpty else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Best window title match: exact, then "<name> — …" / "<name> - …", then contains.
    static func bestWindowIndex(titles: [String], names: [String]) -> Int? {
        for name in names {
            if let index = titles.firstIndex(of: name) { return index }
        }
        for name in names {
            if let index = titles.firstIndex(where: { $0.hasPrefix("\(name) — ") || $0.hasPrefix("\(name) - ") }) {
                return index
            }
        }
        for name in names {
            if let index = titles.firstIndex(where: { $0.contains(name) }) { return index }
        }
        return nil
    }

    /// Codex app deep link for a thread (found in the app bundle, not documented).
    static func codexAppURL(threadId: String) -> URL? {
        guard threadId.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "codex://threads/\(threadId)")
    }

    /// Claude.app deep link for a local session id.
    static func claudeAppURL(appSessionId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: appSessionId)]
        return components.url
    }
}
