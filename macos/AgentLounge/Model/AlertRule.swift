import Foundation

/// What an alert is about (PLAN D5). Each kind has its own sound and notification setting.
nonisolated enum AlertKind: String, CaseIterable, Codable, Hashable, Sendable {
    case needsInput
    case done
    case error

    var label: String {
        switch self {
        case .needsInput: "Needs input"
        case .done: "Done"
        case .error: "Error"
        }
    }
}

/// Where a session comes from, for the per-source on/off setting (PLAN §6).
nonisolated enum SessionSource: String, CaseIterable, Codable, Hashable, Sendable {
    case claudeCLI
    case claudeApp
    case codex

    var label: String {
        switch self {
        case .claudeCLI: "Claude Code CLI"
        case .claudeApp: "Claude Code in Claude.app"
        case .codex: "Codex (CLI and app)"
        }
    }
}

nonisolated extension AgentSession {
    var source: SessionSource {
        if agent == .codex { return .codex }
        return host == .claudeApp ? .claudeApp : .claudeCLI
    }
}

/// Decides when a hook event deserves an alert. Pure, so it can be unit tested.
nonisolated enum AlertRule {
    /// - Parameters:
    ///   - before: card state before the event, nil for a new card.
    ///   - after: card state after the event.
    static func alert(for kind: AgentEvent.Kind, before: SessionState?, after: SessionState) -> AlertKind? {
        guard before != after else { return nil }
        switch after {
        case .needsInput:
            return .needsInput
        case .error:
            return .error
        case .idle:
            // Only a finished turn. Not a new session, an interrupt, or a resume.
            guard case .stop = kind, before == .running || before == .needsInput else { return nil }
            return .done
        case .running:
            return nil
        }
    }

    /// Notification / log text for an alert.
    static func message(for alert: AlertKind, session: AgentSession) -> String {
        switch alert {
        case .needsInput:
            session.attention ?? "Waiting for your input"
        case .done:
            session.lastAssistantMessage?.firstLine ?? "Finished the turn"
        case .error:
            session.attention ?? "Stopped with an error"
        }
    }
}

/// Auto-hide of done cards (PLAN §6). Pure, so it can be unit tested.
nonisolated enum AutoHide {
    /// Idle cards whose last event is older than `minutes`. `minutes == 0` = off.
    static func expiredIDs(_ sessions: [AgentSession], minutes: Int, now: Date) -> [AgentSession.ID] {
        guard minutes > 0 else { return [] }
        let limit = TimeInterval(minutes * 60)
        return sessions
            .filter { $0.state == .idle && now.timeIntervalSince($0.lastEventAt) >= limit }
            .map(\.id)
    }
}
