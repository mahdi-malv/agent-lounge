import Foundation
import Observation
import os

/// Holds all cards, fed by hook events, transcripts and backfill.
@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []
    private var hiddenIDs: Set<AgentSession.ID> = []
    private var deletedIDs: Set<AgentSession.ID> = []

    @ObservationIgnored
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "SessionStore")

    /// Sources turned off in settings. Their cards stay up to date but are not shown.
    var disabledSources: Set<SessionSource> = []

    var visibleSessions: [AgentSession] {
        sessions.filter { !hiddenIDs.contains($0.id) && !deletedIDs.contains($0.id) && !disabledSources.contains($0.source) }
    }

    func isVisible(_ id: AgentSession.ID) -> Bool {
        visibleSessions.contains { $0.id == id }
    }

    var summary: StoreSummary {
        StoreSummary(states: visibleSessions.map(\.state))
    }

    func session(_ id: AgentSession.ID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    func isDeleted(_ id: AgentSession.ID) -> Bool {
        deletedIDs.contains(id)
    }

    /// Feed one hook event through the state machine. Returns true when it created a card.
    @discardableResult
    func apply(_ event: AgentEvent) -> Bool {
        let id = event.cardID
        if case .sessionEnd = event.kind {
            remove(id)
            return false
        }
        guard !deletedIDs.contains(id) else { return false }
        let existing = session(id)
        var session = existing ?? SessionReducer.newSession(for: event)
        SessionReducer.apply(event, to: &session)
        upsert(session)
        return existing == nil
    }

    /// Add a card found by backfill. Never replaces a card that hooks already created.
    func insertBackfilled(_ session: AgentSession) {
        guard self.session(session.id) == nil, !deletedIDs.contains(session.id) else { return }
        sessions.append(session)
    }

    /// Merge transcript facts into a card (M3). Hooks stay the source for state and activity.
    func applyTranscript(_ summary: TranscriptSummary, gitBranch: String?, contextLimit: Int, to id: AgentSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[index]
        if let model = summary.model { session.model = model }
        if session.effort == nil { session.effort = summary.effort }
        if session.permissionMode == nil { session.permissionMode = summary.permissionMode }
        if let gitBranch { session.gitBranch = gitBranch }
        if let title = summary.aiTitle { session.aiTitle = title }
        if let title = summary.customTitle { session.customTitle = title }
        if let tokens = summary.contextTokens {
            session.context = ContextUsage(usedTokens: tokens, limitTokens: contextLimit)
        }
        // The Stop hook is fresher; the transcript only fills a gap (backfill).
        if session.lastAssistantMessage == nil { session.lastAssistantMessage = summary.lastAssistantText }
        if summary.isComplete, let first = summary.firstTimestamp, first < session.startedAt {
            session.startedAt = first
        }
        if let last = summary.lastTimestamp, last > session.lastEventAt { session.lastEventAt = last }
        if !summary.tasks.isEmpty {
            session.transcriptTasks = summary.tasks
            session.refreshTasks()
        }
        if session != sessions[index] { sessions[index] = session }
    }

    /// Codex thread name from `~/.codex/session_index.jsonl`.
    func setAITitle(_ title: String, for id: AgentSession.ID) {
        guard !title.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].aiTitle != title else { return }
        sessions[index].aiTitle = title
    }

    /// State guessed from the transcript for a backfilled card (before its first hook event).
    func setBackfilledState(_ state: SessionState, for id: AgentSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].state != state else { return }
        sessions[index].state = state
    }

    func setProcessStartTime(_ startTime: Double, for id: AgentSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].pidStartTime = startTime
    }

    /// Launch facts from `~/.claude/sessions/<pid>.json`.
    func applyRegistry(_ record: ClaudeProcessRecord, to id: AgentSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[index]
        if let cwd = record.cwd, !cwd.isEmpty { session.projectDirectory = cwd }
        if let appSessionId = record.hostSessionId, !appSessionId.isEmpty { session.appSessionId = appSessionId }
        if let startedAt = record.startedAt.map({ Date(timeIntervalSince1970: $0 / 1000) }), startedAt < session.startedAt {
            session.startedAt = startedAt
        }
        if session != sessions[index] { sessions[index] = session }
    }

    /// Insert or replace a session. A new event un-hides a hidden card (PLAN §5).
    func upsert(_ session: AgentSession) {
        guard !deletedIDs.contains(session.id) else { return }
        hiddenIDs.remove(session.id)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    /// The session ended (SessionEnd or PID gone).
    func remove(_ id: AgentSession.ID) {
        sessions.removeAll { $0.id == id }
        hiddenIDs.remove(id)
        deletedIDs.remove(id)
    }

    /// Hide the card until the session's next event.
    func hide(_ id: AgentSession.ID) {
        guard !hiddenIDs.contains(id) else { return }
        hiddenIDs.insert(id)
    }

    /// Remove the card for the rest of the session. Does not stop the agent.
    func delete(_ id: AgentSession.ID) {
        deletedIDs.insert(id)
        sessions.removeAll { $0.id == id }
    }

    /// Set by the app: runs the focus service (PLAN M4).
    @ObservationIgnored
    var focusHandler: ((AgentSession) -> Void)?

    func focus(_ id: AgentSession.ID) {
        guard let session = session(id) else { return }
        guard let focusHandler else {
            logger.info("Focus requested for \(id, privacy: .public); no focus handler")
            return
        }
        focusHandler(session)
    }

    /// Dev aid: add (or reset) the mock cards next to the real ones.
    func addMockSessions(now: Date = .now) {
        for session in MockSessions.make(now: now) {
            deletedIDs.remove(session.id)
            upsert(session)
        }
    }
}
