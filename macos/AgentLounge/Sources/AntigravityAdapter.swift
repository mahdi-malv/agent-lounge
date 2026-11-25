import Foundation

/// Antigravity (`agy` CLI, App, IDE) hook payload → `AgentEvent`.
/// Payloads use camelCase (protojson): `conversationId`, `hookEventName`, `cwd`, `workspacePaths`,
/// `transcriptPath`, `modelName`, `toolCall` (`id`, `name`, `args`), `error`, `terminationReason`.
nonisolated enum AntigravityAdapter {
    static func event(from envelope: HookEnvelope, receivedAt: Date) -> AgentEvent? {
        let payload = envelope.payload
        guard let sessionId = payload["conversationId"]?.stringValue, !sessionId.isEmpty,
              let name = payload["hookEventName"]?.stringValue else { return nil }

        let cwd = payload["cwd"]?.stringValue
            ?? (payload["workspacePaths"].flatMap { value -> String? in
                if case .array(let items) = value { return items.first?.stringValue }
                return nil
            })
        let rawModel = payload["modelName"]?.stringValue
        let model = (rawModel == nil || rawModel == "auto" || rawModel?.isEmpty == true) ? nil : rawModel

        return AgentEvent(
            agent: .antigravity,
            sessionId: sessionId,
            kind: kind(name: name, payload: payload),
            timestamp: envelope.sentAt.map { Date(timeIntervalSince1970: $0) } ?? receivedAt,
            cwd: cwd,
            transcriptPath: payload["transcriptPath"]?.stringValue,
            permissionMode: nil,
            model: model,
            effort: nil,
            title: nil,
            agentId: nil,
            host: envelope.host,
            payload: payload
        )
    }

    private static func kind(name: String, payload: JSONValue) -> AgentEvent.Kind {
        func string(_ key: String) -> String? { payload[key]?.stringValue }
        var tool: ToolCall {
            let call = payload["toolCall"]
            return ToolCall(
                name: call?["name"]?.stringValue ?? "Tool",
                input: call?["args"],
                useId: call?["id"]?.stringValue
            )
        }

        switch name {
        case "SessionStart":
            return .sessionStart(source: string("source"))
        case "PreInvocation":
            return .userPromptSubmit
        case "PreToolUse":
            return .preToolUse(tool)
        case "PostToolUse":
            if let error = string("error"), !error.isEmpty {
                return .postToolUseFailure(tool, error: error)
            }
            return .postToolUse(tool)
        case "Stop":
            let reason = string("terminationReason")
            let error = string("error")
            if reason == "ERROR" || (error != nil && !error!.isEmpty) {
                return .stopFailure(error: error?.isEmpty == false ? error : reason)
            }
            if reason == "USER_CANCELED" {
                return .interrupt
            }
            return .stop(lastMessage: nil)
        case "Notification":
            return .notification(type: string("notificationType") ?? string("type"), message: string("message"))
        case "SessionEnd":
            return .sessionEnd(reason: string("reason"))
        default:
            return .unknown(name)
        }
    }
}
