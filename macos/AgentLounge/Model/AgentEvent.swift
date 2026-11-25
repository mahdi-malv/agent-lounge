import Foundation

/// Normalized hook event. Source adapters (`ClaudeAdapter`, `CodexAdapter`) produce it.
nonisolated struct AgentEvent: Sendable {
    enum Kind: Sendable, Equatable {
        case sessionStart(source: String?)
        case userPromptSubmit
        case preToolUse(ToolCall)
        case postToolUse(ToolCall)
        case postToolUseFailure(ToolCall, error: String?)
        case permissionRequest(ToolCall)
        case notification(type: String?, message: String?)
        case subagentStart
        case subagentStop
        case taskCreated(id: String?, subject: String?)
        case taskCompleted(id: String?)
        case stop(lastMessage: String?)
        case stopFailure(error: String?)
        /// Codex: the user stopped the turn.
        case interrupt
        case preCompact
        case postCompact
        case cwdChanged
        case sessionEnd(reason: String?)
        case unknown(String)
    }

    var agent: AgentKind
    /// Agent's own session id (Claude `session_id`, Codex thread id).
    var sessionId: String
    var kind: Kind
    var timestamp: Date
    var cwd: String?
    var transcriptPath: String?
    var permissionMode: String?
    var model: String?
    var effort: String?
    var title: String?
    /// Set when the event comes from inside a subagent.
    var agentId: String?
    var host: HostInfo
    /// Raw hook payload, for fields the adapter does not map yet.
    var payload: JSONValue

    /// Card id. Prefixed so Claude and Codex ids cannot collide.
    var cardID: String { "\(agent.rawValue):\(sessionId)" }
}

nonisolated extension AgentEvent.Kind {
    /// Short text for logs, e.g. "PreToolUse Bash".
    var logDescription: String {
        switch self {
        case .sessionStart(let source): "SessionStart \(source ?? "-")"
        case .userPromptSubmit: "UserPromptSubmit"
        case .preToolUse(let tool): "PreToolUse \(tool.name)"
        case .postToolUse(let tool): "PostToolUse \(tool.name)"
        case .postToolUseFailure(let tool, _): "PostToolUseFailure \(tool.name)"
        case .permissionRequest(let tool): "PermissionRequest \(tool.name)"
        case .notification(let type, _): "Notification \(type ?? "-")"
        case .subagentStart: "SubagentStart"
        case .subagentStop: "SubagentStop"
        case .taskCreated: "TaskCreated"
        case .taskCompleted: "TaskCompleted"
        case .stop: "Stop"
        case .stopFailure: "StopFailure"
        case .interrupt: "Interrupt"
        case .preCompact: "PreCompact"
        case .postCompact: "PostCompact"
        case .cwdChanged: "CwdChanged"
        case .sessionEnd(let reason): "SessionEnd \(reason ?? "-")"
        case .unknown(let name): "Unknown \(name)"
        }
    }
}

nonisolated struct ToolCall: Sendable, Equatable {
    var name: String
    var input: JSONValue?
    var useId: String?

    /// Short target of the call (command, file, pattern, URL), first line only.
    var briefTarget: String? {
        let keys = [
            "command", "CommandLine", "file_path", "Path", "TargetFile", "AbsolutePath",
            "notebook_path", "path", "pattern", "Pattern", "url", "Url", "query", "Query",
            "toolSummary", "description",
        ]
        for key in keys {
            if let value = input?[key]?.stringValue?.firstLine {
                return value.count > 80 ? String(value.prefix(79)) + "…" : value
            }
        }
        return nil
    }
}
