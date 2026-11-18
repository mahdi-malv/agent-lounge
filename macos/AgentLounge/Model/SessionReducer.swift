import Foundation

/// Card state machine (PLAN §5). Pure functions, so tests need no app.
nonisolated enum SessionReducer {
    /// Consecutive tool failures before the card shows `error`.
    static let failureThreshold = 3

    static func newSession(for event: AgentEvent) -> AgentSession {
        AgentSession(
            id: event.cardID,
            agent: event.agent,
            host: event.host.hostKind,
            state: .idle,
            cwd: event.cwd ?? "",
            startedAt: event.timestamp,
            lastEventAt: event.timestamp,
            agentSessionId: event.sessionId
        )
    }

    static func apply(_ event: AgentEvent, to session: inout AgentSession) {
        session.lastEventAt = max(session.lastEventAt, event.timestamp)
        session.hostInfo = event.host
        session.host = event.host.hostKind
        if let value = event.permissionMode { session.permissionMode = value }
        if let value = event.effort { session.effort = value }
        if let value = event.model { session.model = value }
        if let value = event.title, !value.isEmpty { session.title = value }
        if let value = event.transcriptPath { session.transcriptPath = value }
        if let pid = event.host.agentPID(for: event.agent) { session.pid = pid }
        if session.cwd.isEmpty, let cwd = event.cwd { session.cwd = cwd }

        switch event.kind {
        case .sessionStart(let source):
            if let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }
            // "compact" restarts the context inside a running turn. Other sources wait for a prompt.
            if source != "compact" {
                session.state = .idle
                session.activity = nil
                session.attention = nil
            }

        case .userPromptSubmit:
            session.state = .running
            session.activity = nil
            session.attention = nil
            session.consecutiveToolFailures = 0

        case .preToolUse(let tool):
            session.activity = ToolActivity.describe(tool)
            if let waiting = ToolActivity.waitingText(tool) {
                // AskUserQuestion / ExitPlanMode block until the user answers.
                session.state = .needsInput
                session.attention = waiting
            } else {
                session.state = .running
                session.attention = nil
            }

        case .postToolUse(let tool):
            session.consecutiveToolFailures = 0
            if session.state == .needsInput || session.state == .error {
                session.state = .running
                session.attention = nil
            }
            if session.hookTasks.apply(toolName: tool.name, input: tool.input, response: event.payload["tool_response"]) {
                session.refreshTasks()
            }

        case .postToolUseFailure(let tool, let error):
            session.consecutiveToolFailures += 1
            if session.consecutiveToolFailures >= failureThreshold {
                session.state = .error
                let reason = error?.firstLine.map { ": \($0)" } ?? ""
                session.attention = "\(tool.name) failed \(session.consecutiveToolFailures) times\(reason)"
            } else if session.state == .needsInput {
                session.state = .running
                session.attention = nil
            }

        case .permissionRequest(let tool):
            session.state = .needsInput
            session.attention = tool.briefTarget.map { "Allow \(tool.name): \($0)?" } ?? "Allow \(tool.name)?"

        case .notification(let type, let message):
            switch type {
            case "permission_prompt", "idle_prompt", "elicitation_dialog":
                session.state = .needsInput
                if let message, !message.isEmpty {
                    session.attention = message
                } else if session.attention == nil {
                    session.attention = "Waiting for your input"
                }
            default:
                break
            }

        case .subagentStart:
            session.subagentCount += 1

        case .subagentStop:
            session.subagentCount = max(0, session.subagentCount - 1)

        // Same facts as PostToolUse(TaskCreate/TaskUpdate); applying both is harmless.
        case .taskCreated(let id, let subject):
            if let id {
                session.hookTasks.create(id: id, subject: subject, activeForm: nil)
                session.refreshTasks()
            }

        case .taskCompleted(let id):
            if let id {
                session.hookTasks.update(id: id, status: "completed")
                session.refreshTasks()
            }

        case .stop(let lastMessage):
            session.state = .idle
            session.activity = nil
            session.attention = nil
            session.subagentCount = 0
            if let lastMessage, !lastMessage.isEmpty {
                session.lastAssistantMessage = lastMessage
            }

        case .interrupt:
            session.state = .idle
            session.activity = nil
            session.attention = nil
            session.subagentCount = 0

        case .stopFailure(let error):
            session.state = .error
            session.activity = nil
            session.attention = error?.firstLine ?? "The turn failed"

        case .preCompact:
            session.activity = "Compacting context"

        case .postCompact:
            if session.activity == "Compacting context" {
                session.activity = nil
            }

        case .cwdChanged:
            if let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }

        case .sessionEnd, .unknown:
            break
        }
    }
}
