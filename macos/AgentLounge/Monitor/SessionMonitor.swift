import Foundation
import os

/// Keeps cards true to the real sessions (PLAN M3):
/// - transcript facts (model, context, branch, title, tasks) every tick,
/// - PID liveness (crash = no SessionEnd),
/// - backfill of sessions that started before the app: Claude from `~/.claude/sessions`,
///   Codex CLI from running `codex` processes + `~/.codex/state_<n>.sqlite` (`CodexBackfill`),
/// - Codex thread names from `~/.codex/session_index.jsonl`.
final class SessionMonitor {
    static let tickInterval: Duration = .seconds(2)
    /// Backfill runs every this many ticks (also catches sessions without hooks).
    static let backfillEveryTicks = 30

    /// Minutes after which done cards hide (settings). 0 = off.
    var autoHideDoneMinutes: () -> Int = { 0 }

    private let store: SessionStore
    private let transcripts = TranscriptReader()
    private var loop: Task<Void, Never>?
    private var tick = 0
    private var readsInFlight: Set<AgentSession.ID> = []
    /// Backfilled Codex cards with no hook event yet: state follows the rollout (hooks may be missing).
    private var stateFromTranscript: Set<AgentSession.ID> = []
    private var defaultModelSetting: String?
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Monitor")

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        guard loop == nil else { return }
        defaultModelSetting = ClaudeFiles.defaultModelSetting()
        backfill()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.onTick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Called after the store applied a hook event.
    func eventApplied(_ event: AgentEvent, createdCard: Bool) {
        stateFromTranscript.remove(event.cardID)
        if case .sessionEnd = event.kind {
            stateFromTranscript.remove(event.cardID)
            if let path = event.transcriptPath {
                Task { await transcripts.forget(path: path) }
            }
            return
        }
        if createdCard {
            if event.agent == .claude { adoptRegistryRecord(for: event.cardID) }
            refreshTranscript(event.cardID)
        }
        // Codex names a thread after its first turn.
        if event.agent == .codex, createdCard || isStop(event.kind) {
            refreshCodexTitles()
        }
    }

    // MARK: - Tick

    private func onTick() {
        tick += 1
        checkLiveness()
        for id in AutoHide.expiredIDs(store.visibleSessions, minutes: autoHideDoneMinutes(), now: .now) {
            store.hide(id)
        }
        for session in store.sessions where session.transcriptPath != nil {
            refreshTranscript(session.id)
        }
        if tick % Self.backfillEveryTicks == 0 {
            defaultModelSetting = ClaudeFiles.defaultModelSetting()
            backfill()
            refreshCodexTitles()
        }
    }

    private func isStop(_ kind: AgentEvent.Kind) -> Bool {
        if case .stop = kind { true } else { false }
    }

    private func refreshCodexTitles() {
        let ids = store.sessions.filter { $0.agent == .codex }.map(\.id)
        guard !ids.isEmpty else { return }
        let names = CodexFiles.threadNames()
        for id in ids {
            guard let threadId = store.session(id)?.agentSessionId, let name = names[threadId] else { continue }
            store.setAITitle(name, for: id)
        }
    }

    private func checkLiveness() {
        for session in store.sessions {
            guard let pid = session.pid else { continue }
            guard let info = ProcessInspector.info(pid), !info.isZombie else {
                logger.info("Process \(pid) of \(session.id, privacy: .public) is gone")
                store.remove(session.id)
                stateFromTranscript.remove(session.id)
                continue
            }
            if let start = session.pidStartTime {
                if abs(info.startTime - start) >= 1 {
                    logger.info("PID \(pid) of \(session.id, privacy: .public) was reused")
                    store.remove(session.id)
                    stateFromTranscript.remove(session.id)
                }
            } else {
                store.setProcessStartTime(info.startTime, for: session.id)
            }
        }
    }

    // MARK: - Transcript

    private func refreshTranscript(_ id: AgentSession.ID) {
        guard !readsInFlight.contains(id), let path = store.session(id)?.transcriptPath else { return }
        readsInFlight.insert(id)
        Task {
            let format = TranscriptFormat(store.session(id)?.agent ?? .claude)
            let summary = await transcripts.read(path: path, format: format)
            readsInFlight.remove(id)
            guard let summary, let session = store.session(id) else { return }
            if stateFromTranscript.contains(id), let state = summary.inferredState {
                store.setBackfilledState(state, for: id)
            }
            let branch = summary.gitBranch.flatMap { $0 == "HEAD" ? nil : $0 }
                ?? (session.cwd.isEmpty ? nil : GitInfo.branch(at: session.cwd))
            let limit = summary.contextWindow ?? ContextWindow.limit(
                model: summary.model ?? session.model,
                peakTokens: summary.peakContextTokens,
                defaultModelSetting: defaultModelSetting
            )
            store.applyTranscript(summary, gitBranch: branch, contextLimit: limit, to: id)
        }
    }

    /// Hook-created card: take launch folder, start time and Claude.app id from the registry.
    private func adoptRegistryRecord(for id: AgentSession.ID) {
        guard let session = store.session(id), let pid = session.pid,
              let record = ClaudeFiles.record(pid: pid), record.sessionId == session.agentSessionId else { return }
        store.applyRegistry(record, to: id)
    }

    // MARK: - Backfill

    func backfill() {
        backfillClaude()
        backfillCodex()
    }

    private func backfillClaude() {
        for record in ClaudeFiles.liveSessionRecords() {
            let id = "\(AgentKind.claude.rawValue):\(record.sessionId)"
            if store.session(id) != nil {
                store.applyRegistry(record, to: id)
                continue
            }
            guard !store.isDeleted(id), let session = makeSession(from: record, id: id) else { continue }
            logger.info("Backfilled \(id, privacy: .public)")
            store.insertBackfilled(session)
            refreshTranscript(id)
        }
    }

    /// Codex CLI sessions (PLAN M5). The Codex app is not backfilled: one app-server hosts all its threads,
    /// so there is no per-thread liveness; its cards come from hooks.
    private func backfillCodex() {
        let processes = Self.codexProcesses()
        guard let oldest = processes.map(\.startTime).min() else { return }
        let threads = CodexStateDB.threads(updatedSince: oldest - CodexBackfill.slack)
        for match in CodexBackfill.match(processes: processes, threads: threads) {
            let id = "\(AgentKind.codex.rawValue):\(match.thread.id)"
            guard store.session(id) == nil, !store.isDeleted(id) else { continue }
            logger.info("Backfilled \(id, privacy: .public) (pid \(match.process.pid))")
            store.insertBackfilled(makeSession(from: match, id: id))
            stateFromTranscript.insert(id)
            refreshTranscript(id)
        }
    }

    /// Running Codex CLI processes of this user (`codex` binary, not a child of another `codex`).
    private static func codexProcesses() -> [CodexProcess] {
        ProcessInspector.allPIDs().compactMap { pid in
            guard let info = ProcessInspector.info(pid), !info.isZombie, info.name == "codex",
                  ProcessInspector.info(info.parentPID)?.name != "codex",
                  let cwd = ProcessInspector.currentDirectory(pid),
                  let arguments = ProcessInspector.arguments(pid) else { return nil }
            return CodexProcess(pid: pid, startTime: info.startTime, workingDirectory: cwd, arguments: arguments)
        }
    }

    private func makeSession(from match: CodexBackfill.Match, id: AgentSession.ID) -> AgentSession {
        let thread = match.thread
        let environment = ProcessInspector.environment(match.process.pid) ?? [:]
        let host = HostInfo(environment: environment, processes: ProcessInspector.ancestry(from: match.process.pid))
        var session = AgentSession(
            id: id,
            agent: .codex,
            host: host.hostKind,
            state: .idle,
            cwd: thread.cwd,
            startedAt: Date(timeIntervalSince1970: thread.createdAt),
            lastEventAt: Date(timeIntervalSince1970: thread.updatedAt),
            agentSessionId: thread.id,
            transcriptPath: thread.rolloutPath,
            pid: match.process.pid,
            hostInfo: host
        )
        session.pidStartTime = match.process.startTime
        session.model = thread.model
        session.effort = thread.effort
        session.gitBranch = thread.gitBranch
        session.aiTitle = thread.name
        return session
    }

    private func makeSession(from record: ClaudeProcessRecord, id: AgentSession.ID) -> AgentSession? {
        guard let info = ProcessInspector.info(record.pid) else { return nil }
        let environment = ProcessInspector.environment(record.pid) ?? [:]
        var host = HostInfo(environment: environment, processes: ProcessInspector.ancestry(from: record.pid))
        if host.entrypoint == nil { host.entrypoint = record.entrypoint }

        let now = Date.now
        let startedAt = record.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
        let updatedAt = record.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? startedAt
        let cwd = record.cwd ?? ""

        var session = AgentSession(
            id: id,
            agent: .claude,
            host: host.hostKind,
            state: record.status == "busy" ? .running : .idle,
            cwd: cwd,
            startedAt: startedAt,
            lastEventAt: updatedAt,
            agentSessionId: record.sessionId,
            transcriptPath: cwd.isEmpty ? nil : ClaudeFiles.transcriptPath(cwd: cwd, sessionId: record.sessionId),
            pid: record.pid,
            hostInfo: host
        )
        session.pidStartTime = info.startTime
        session.appSessionId = record.hostSessionId.flatMap { $0.isEmpty ? nil : $0 }
        session.projectDirectory = record.cwd
        return session
    }
}
