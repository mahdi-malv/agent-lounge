import Foundation

/// Card state (PLAN §5).
nonisolated enum SessionState: String, CaseIterable, Codable, Hashable, Sendable {
    case running
    case needsInput
    case idle
    case error

    /// Higher value = more urgent. Used for the status-item dot.
    var urgency: Int {
        switch self {
        case .needsInput: 3
        case .error: 2
        case .running: 1
        case .idle: 0
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .needsInput: "Needs input"
        case .idle: "Done"
        case .error: "Error"
        }
    }
}

nonisolated enum AgentKind: String, CaseIterable, Codable, Hashable, Sendable {
    case claude
    case codex
    case antigravity

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }
}

/// Where the agent runs. Drives the host badge now and focus in M4.
nonisolated enum HostKind: Codable, Hashable, Sendable {
    case cmux
    case zed
    case claudeApp
    /// Codex desktop app (bundle `ChatGPT.app`, id `com.openai.codex`).
    case codexApp
    case terminal(String)
    case unknown

    var label: String {
        switch self {
        case .cmux: "cmux"
        case .zed: "Zed"
        case .claudeApp: "Claude.app"
        case .codexApp: "Codex app"
        case .terminal(let name): name
        case .unknown: "other"
        }
    }
}

nonisolated struct AgentTask: Identifiable, Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case pending
        case inProgress
        case completed
    }

    let id: String
    var subject: String
    var activeForm: String?
    var status: Status
}

nonisolated struct ContextUsage: Codable, Hashable, Sendable {
    var usedTokens: Int
    var limitTokens: Int

    var fraction: Double {
        limitTokens > 0 ? Double(usedTokens) / Double(limitTokens) : 0
    }
}

nonisolated struct TaskProgress: Hashable, Sendable {
    let done: Int
    let total: Int
    let active: AgentTask?

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// Text next to the counter: active task, or nil.
    var label: String? {
        if let active { return active.activeForm ?? active.subject }
        return done == total ? "All done" : nil
    }
}

/// One agent session = one card.
nonisolated struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var agent: AgentKind
    var host: HostKind
    var state: SessionState
    var cwd: String
    var startedAt: Date
    var lastEventAt: Date

    var title: String? = nil
    var gitBranch: String? = nil
    /// Current activity from the last tool, e.g. "Editing Foo.swift".
    var activity: String? = nil
    /// Reason for `needsInput` or `error`.
    var attention: String? = nil
    var tasks: [AgentTask] = []
    var model: String? = nil
    var effort: String? = nil
    var permissionMode: String? = nil
    var subagentCount: Int = 0
    var context: ContextUsage? = nil
    var lastAssistantMessage: String? = nil

    /// Agent's own session id (Claude `session_id`, Codex thread id). `id` adds a source prefix.
    var agentSessionId: String? = nil
    var transcriptPath: String? = nil
    /// Agent process, for liveness (M3) and focus (M4).
    var pid: Int32? = nil
    /// Latest host facts from the hook, for focus (M4).
    var hostInfo: HostInfo? = nil
    var consecutiveToolFailures: Int = 0

    /// Process start time (Unix seconds) of `pid`. Detects PID reuse.
    var pidStartTime: Double? = nil
    /// Claude.app session id (`local_…`), from `~/.claude/sessions` (M5 focus).
    var appSessionId: String? = nil
    /// Titles from the transcript: `/rename` and the automatic title.
    var customTitle: String? = nil
    var aiTitle: String? = nil
    /// Task list sources. `tasks` is their merge (see `TaskBook`).
    var hookTasks = TaskBook()
    var transcriptTasks = TaskBook()

    /// Folder the agent was started in (from `~/.claude/sessions`). `cwd` can move into subfolders.
    var projectDirectory: String? = nil

    var projectName: String {
        let directory = projectDirectory ?? cwd
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    /// Explicit title as is; a transcript title gets the project name in front.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let name = customTitle ?? aiTitle, !name.isEmpty { return "\(projectName) · \(name)" }
        return projectName
    }

    /// Recompute `tasks` from the two task books. Keeps `tasks` when both are empty (mocks).
    mutating func refreshTasks() {
        guard !hookTasks.isEmpty || !transcriptTasks.isEmpty else { return }
        tasks = TaskBook.merged(base: transcriptTasks, overlay: hookTasks)
    }

    var progress: TaskProgress? {
        guard !tasks.isEmpty else { return nil }
        return TaskProgress(
            done: tasks.count(where: { $0.status == .completed }),
            total: tasks.count,
            active: tasks.first(where: { $0.status == .inProgress })
        )
    }
}

/// Number of visible cards in one state.
nonisolated struct StateCount: Equatable, Hashable, Sendable {
    var state: SessionState
    var count: Int
}

nonisolated struct StoreSummary: Equatable, Sendable {
    /// Visible cards per state, most urgent state first. Only states that have cards.
    var counts: [StateCount]

    init(states: [SessionState]) {
        counts = SessionState.allCases
            .map { state in StateCount(state: state, count: states.count { $0 == state }) }
            .filter { $0.count > 0 }
            .sorted { $0.state.urgency > $1.state.urgency }
    }

    var count: Int { counts.reduce(0) { $0 + $1.count } }

    /// Most urgent state of the visible cards, or nil when there are none.
    var topState: SessionState? { counts.first?.state }

    /// Spoken form, e.g. "1 running, 5 done".
    var spokenCounts: String {
        counts.map { "\($0.count) \($0.state.label.lowercased())" }.joined(separator: ", ")
    }
}

nonisolated extension String {
    /// First non-empty line, trimmed. Nil when the string is blank.
    var firstLine: String? {
        let line = split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}
