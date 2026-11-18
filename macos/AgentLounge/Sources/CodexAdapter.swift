import Foundation

/// Codex CLI hook payload → `AgentEvent`.
/// Docs: https://developers.openai.com/codex/hooks (PLAN §2 "Codex").
/// Payloads look like Claude's (`session_id`, `hook_event_name`, `tool_name`, `tool_input`, …), with
/// `model` on every event and `turn_id` on turn events. Subagent events carry the parent `session_id`.
nonisolated enum CodexAdapter {
    static func event(from envelope: HookEnvelope, receivedAt: Date) -> AgentEvent? {
        let payload = envelope.payload
        guard let sessionId = payload["session_id"]?.stringValue, !sessionId.isEmpty,
              let name = payload["hook_event_name"]?.stringValue else { return nil }

        return AgentEvent(
            agent: .codex,
            sessionId: sessionId,
            kind: kind(name: name, payload: payload),
            timestamp: envelope.sentAt.map { Date(timeIntervalSince1970: $0) } ?? receivedAt,
            cwd: payload["cwd"]?.stringValue,
            transcriptPath: payload["transcript_path"]?.stringValue,
            permissionMode: payload["permission_mode"]?.stringValue,
            model: payload["model"]?.stringValue,
            effort: nil,
            title: nil,
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
        case "PermissionRequest": return .permissionRequest(tool)
        case "SubagentStart": return .subagentStart
        case "SubagentStop": return .subagentStop
        case "Stop": return .stop(lastMessage: string("last_assistant_message"))
        case "Interrupt": return .interrupt
        case "PreCompact": return .preCompact
        case "PostCompact": return .postCompact
        case "SessionEnd": return .sessionEnd(reason: string("reason"))
        default: return .unknown(name)
        }
    }
}
