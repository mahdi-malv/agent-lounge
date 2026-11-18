import Foundation
@testable import AgentLounge

/// Builds hook envelopes like `lounge-hook` sends them.
enum TestEvents {
    static let sessionId = "11111111-2222-3333-4444-555555555555"

    static let cmuxHost: [String: Any] = [
        "termProgram": "ghostty",
        "bundleId": "com.cmuxterm.app",
        "cmuxSurfaceId": "SURFACE-1",
        "cmuxWorkspaceId": "WORKSPACE-1",
        "tty": "ttys002",
        "processes": [
            ["pid": 900, "ppid": 800, "name": "sh", "path": "/bin/sh"],
            ["pid": 800, "ppid": 700, "name": "2.1.327", "path": "/Users/u/.local/share/claude/versions/2.1.327", "tty": "ttys002"],
            ["pid": 700, "ppid": 1, "name": "cmux", "path": "/Applications/cmux.app/Contents/MacOS/cmux"],
        ],
    ]

    static func envelopeData(
        _ hookEventName: String,
        sessionId: String = sessionId,
        host: [String: Any] = cmuxHost,
        sentAt: Double = 1_000,
        source: String = "claude",
        extra: [String: Any] = [:]
    ) -> Data {
        var payload: [String: Any] = [
            "session_id": sessionId,
            "hook_event_name": hookEventName,
            "cwd": "/Users/u/code/my-app",
            "transcript_path": "/Users/u/.claude/projects/x/\(sessionId).jsonl",
            "permission_mode": "default",
        ]
        payload.merge(extra) { _, new in new }
        let envelope: [String: Any] = ["v": 1, "source": source, "sentAt": sentAt, "host": host, "payload": payload]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    static func event(
        _ hookEventName: String,
        sessionId: String = sessionId,
        host: [String: Any] = cmuxHost,
        sentAt: Double = 1_000,
        extra: [String: Any] = [:]
    ) -> AgentEvent {
        let data = envelopeData(hookEventName, sessionId: sessionId, host: host, sentAt: sentAt, extra: extra)
        let envelope = try! JSONDecoder().decode(HookEnvelope.self, from: data)
        return ClaudeAdapter.event(from: envelope, receivedAt: Date(timeIntervalSince1970: sentAt))!
    }

    static func bash(_ command: String) -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": "toolu_1"]
    }
}
