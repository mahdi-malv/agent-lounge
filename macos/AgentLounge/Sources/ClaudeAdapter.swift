import Foundation

/// Claude Code hook payload → `AgentEvent`.
/// Field names: https://code.claude.com/docs/en/hooks (PLAN §2).
nonisolated enum ClaudeAdapter {
    static func event(from envelope: HookEnvelope, receivedAt: Date) -> AgentEvent? {
        let payload = envelope.payload
        guard let sessionId = payload["session_id"]?.stringValue, !sessionId.isEmpty,
              let name = payload["hook_event_name"]?.stringValue else { return nil }

        let timestamp: Date = envelope.sentAt.map { Date(timeIntervalSince1970: $0) } ?? receivedAt
        // `model` and `effort` can be a string or an object, depending on the version.
        let model: String? = payload["model"]?.stringValue ?? payload["model"]?["id"]?.stringValue
        let effort: String? = payload["effort"]?.stringValue ?? payload["effort"]?["level"]?.stringValue

        return AgentEvent(
            agent: .claude,
            sessionId: sessionId,
            kind: kind(name: name, payload: payload),
            timestamp: timestamp,
            cwd: payload["cwd"]?.stringValue,
            transcriptPath: payload["transcript_path"]?.stringValue,
            permissionMode: payload["permission_mode"]?.stringValue,
            model: model,
            effort: effort,
            title: payload["session_title"]?.stringValue,
            agentId: payload["agent_id"]?.stringValue,
            host: envelope.host,
            payload: payload
        )
    }

    private static func kind(name: String, payload: JSONValue) -> AgentEvent.Kind {
        func string(_ key: String) -> String? { payload[key]?.stringValue }
        var tool: ToolCall {
            ToolCall(name: string("tool_name") ?? "Tool", input: payload["tool_input"], useId: string("tool_use_id"))
        }

        switch name {
        case "SessionStart": return .sessionStart(source: string("source"))
        case "UserPromptSubmit": return .userPromptSubmit
        case "PreToolUse": return .preToolUse(tool)
        case "PostToolUse": return .postToolUse(tool)
        case "PostToolUseFailure": return .postToolUseFailure(tool, error: string("error"))
        case "PermissionRequest": return .permissionRequest(tool)
        case "Notification": return .notification(type: string("notification_type"), message: string("message"))
        case "SubagentStart": return .subagentStart
        case "SubagentStop": return .subagentStop
        case "TaskCreated": return .taskCreated(id: string("task_id"), subject: string("task_subject"))
        case "TaskCompleted": return .taskCompleted(id: string("task_id"))
        case "Stop": return .stop(lastMessage: string("last_assistant_message"))
        case "StopFailure": return .stopFailure(error: string("error") ?? string("message"))
        case "PreCompact": return .preCompact
        case "PostCompact": return .postCompact
        case "CwdChanged": return .cwdChanged
        case "SessionEnd": return .sessionEnd(reason: string("reason"))
        default: return .unknown(name)
        }
    }
}
