import Foundation
import Testing
@testable import AgentLounge

/// Codex hook payloads and rollout lines, shaped like Codex CLI 0.169 (captured 2026-11-18).
private enum Codex {
    static let threadId = "01a1ec24-bff7-7e83-b963-9f28e6dd5eb9"

    /// Codex CLI in Ghostty: hook → codex (inside CodexCLI.app) → zsh → login → Ghostty.
    static let ghosttyHost: [String: Any] = [
        "termProgram": "ghostty",
        "bundleId": "com.mitchellh.ghostty",
        "tty": "ttys002",
        "processes": [
            ["pid": 500, "ppid": 400, "name": "codex", "path": "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"],
            ["pid": 400, "ppid": 300, "name": "zsh", "path": "/bin/zsh", "tty": "ttys002"],
            ["pid": 300, "ppid": 200, "name": "login", "path": "/usr/bin/login", "tty": "ttys002"],
            ["pid": 200, "ppid": 1, "name": "ghostty", "path": "/Applications/Ghostty.app/Contents/MacOS/ghostty"],
        ],
    ]

    /// Codex desktop app: hook → codex app-server → ChatGPT.app.
    static let appHost: [String: Any] = [
        "bundleId": "com.openai.codex",
        "processes": [
            ["pid": 610, "ppid": 600, "name": "codex", "path": "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"],
            ["pid": 600, "ppid": 1, "name": "ChatGPT", "path": "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"],
        ],
    ]

    static func event(_ name: String, host: [String: Any] = ghosttyHost, sentAt: Double = 1_000, extra: [String: Any] = [:]) -> AgentEvent {
        var payload: [String: Any] = ["model": "gpt-6-sol", "turn_id": "turn-1"]
        payload.merge(extra) { _, new in new }
        let data = TestEvents.envelopeData(name, sessionId: threadId, host: host, sentAt: sentAt, source: "codex", extra: payload)
        let envelope = try! JSONDecoder().decode(HookEnvelope.self, from: data)
        return CodexAdapter.event(from: envelope, receivedAt: Date(timeIntervalSince1970: sentAt))!
    }

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Rollout line with Codex's key order: timestamp, ordinal, type, payload (payload `type` first).
    static func rollout(_ type: String, _ payloadType: String?, _ fields: [String: Any] = [:], time: String = "2026-11-18T00:53:20.000Z") -> String {
        var payload = line(fields)
        if let payloadType {
            payload = "{\"type\":\"\(payloadType)\"" + (fields.isEmpty ? "}" : "," + payload.dropFirst())
        }
        return "{\"timestamp\":\"\(time)\",\"ordinal\":1,\"type\":\"\(type)\",\"payload\":\(payload)}"
    }
}

struct CodexAdapterTests {
    @Test func mapsTurnEvents() {
        let start = Codex.event("SessionStart", extra: ["source": "startup", "permission_mode": "bypassPermissions"])
        #expect(start.agent == .codex)
        #expect(start.cardID == "codex:\(Codex.threadId)")
        #expect(start.kind == .sessionStart(source: "startup"))
        #expect(start.model == "gpt-6-sol")
        #expect(start.permissionMode == "bypassPermissions")

        let pre = Codex.event("PreToolUse", extra: ["tool_name": "Bash", "tool_input": ["command": "echo hi"], "tool_use_id": "exec-1"])
        #expect(pre.kind == .preToolUse(ToolCall(name: "Bash", input: .object(["command": .string("echo hi")]), useId: "exec-1")))
        #expect(Codex.event("Stop", extra: ["last_assistant_message": "done"]).kind == .stop(lastMessage: "done"))
        #expect(Codex.event("Interrupt").kind == .interrupt)
        #expect(Codex.event("SessionEnd", extra: ["reason": "other"]).kind == .sessionEnd(reason: "other"))
        #expect(Codex.event("PreModelRequest").kind == .unknown("PreModelRequest"))
    }

    @Test func storeRunsAFullTurn() {
        let store = SessionStore()
        store.apply(Codex.event("SessionStart", sentAt: 1_000, extra: ["source": "startup"]))
        store.apply(Codex.event("UserPromptSubmit", sentAt: 1_001, extra: ["prompt": "hi"]))
        store.apply(Codex.event("PreToolUse", sentAt: 1_002, extra: ["tool_name": "Bash", "tool_input": ["command": "make test"]]))
        var card = store.session("codex:\(Codex.threadId)")!
        #expect(card.state == .running)
        #expect(card.activity == "Running make test")
        #expect(card.pid == 500)
        #expect(card.host == .terminal("Ghostty"))

        store.apply(Codex.event("Interrupt", sentAt: 1_003))
        card = store.session(card.id)!
        #expect(card.state == .idle)
        #expect(card.activity == nil)

        store.apply(Codex.event("SessionEnd", sentAt: 1_004))
        #expect(store.sessions.isEmpty)
    }

    @Test func permissionRequestNeedsInput() {
        let store = SessionStore()
        store.apply(Codex.event("PermissionRequest", extra: ["tool_name": "Bash", "tool_input": ["command": "rm -rf build", "description": "Clean"]]))
        let card = store.session("codex:\(Codex.threadId)")!
        #expect(card.state == .needsInput)
        #expect(card.attention == "Allow Bash: rm -rf build?")
    }

    @Test func hostKinds() {
        let app = Codex.event("SessionStart", host: Codex.appHost)
        #expect(app.host.hostKind == .codexApp)
        #expect(app.host.agentPID(for: .codex) == 610)
        #expect(HostInfo(bundleId: "com.openai.codex").hostKind == .codexApp)
    }

    @Test func focusRoutes() {
        var session = SessionReducer.newSession(for: Codex.event("SessionStart", host: Codex.appHost))
        SessionReducer.apply(Codex.event("SessionStart", host: Codex.appHost), to: &session)
        #expect(FocusRoute.route(for: session) == .codexApp(threadId: Codex.threadId))
        #expect(FocusRoute.codexAppURL(threadId: Codex.threadId)?.absoluteString == "codex://threads/\(Codex.threadId)")
        #expect(FocusRoute.codexAppURL(threadId: "a/../b") == nil)

        var cli = SessionReducer.newSession(for: Codex.event("SessionStart"))
        SessionReducer.apply(Codex.event("SessionStart"), to: &cli)
        #expect(FocusRoute.route(for: cli) == .ghostty(tty: "/dev/ttys002"))
    }
}

struct CodexToolTests {
    @Test func patchSummary() {
        let patch = "*** Begin Patch\n*** Update File: Sources/App/Foo.swift\n@@\n-a\n+b\n*** Add File: docs/new.md\n+x\n*** End Patch"
        let tool = ToolCall(name: "apply_patch", input: .object(["command": .string(patch)]))
        #expect(ToolActivity.describe(tool) == "Editing Foo.swift and 1 more")
        #expect(ToolActivity.patchSummary("*** Begin Patch\n*** Delete File: old.txt\n*** End Patch") == "Deleting old.txt")
        #expect(ToolActivity.describe(ToolCall(name: "apply_patch", input: nil)) == "Editing files")
    }

    @Test func requestUserInputWaits() {
        let input: JSONValue = .object(["questions": .array([.object(["question": .string("Which database?")])])])
        #expect(ToolActivity.waitingText(ToolCall(name: "request_user_input", input: input)) == "Which database?")
    }

    @Test func updatePlanReplacesTasks() {
        var book = TaskBook()
        let plan: JSONValue = .object(["plan": .array([
            .object(["step": .string("Read code"), "status": .string("completed")]),
            .object(["step": .string("Write tests"), "status": .string("in_progress")]),
            .object(["step": .string("Ship"), "status": .string("pending")]),
        ])])
        let handled = book.apply(toolName: "update_plan", input: plan, response: nil)
        #expect(handled)
        let tasks = TaskBook.merged(base: TaskBook(), overlay: book)
        #expect(tasks.map(\.subject) == ["Read code", "Write tests", "Ship"])
        #expect(tasks.map(\.status) == [.completed, .inProgress, .pending])
    }
}

struct CodexRolloutTests {
    private func parse(_ lines: [String]) -> TranscriptSummary {
        var parser = CodexRolloutParser()
        parser.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        return parser.summary
    }

    @Test func readsTurnFacts() {
        let summary = parse([
            Codex.rollout("session_meta", nil, ["id": Codex.threadId, "cwd": "/u/app", "git": ["branch": "main"]], time: "2026-11-18T00:53:16.044Z"),
            Codex.rollout("event_msg", "task_started", ["turn_id": "t1", "model_context_window": 258_400]),
            Codex.rollout("turn_context", nil, ["turn_id": "t1", "model": "gpt-6-sol", "effort": "medium"]),
            Codex.rollout("response_item", "reasoning", ["summary": []]),
            Codex.rollout("event_msg", "token_count", ["info": ["last_token_usage": ["input_tokens": 26_211, "output_tokens": 94], "model_context_window": 258_400]]),
            Codex.rollout("event_msg", "task_complete", ["turn_id": "t1", "last_agent_message": "All **done**."], time: "2026-11-18T00:53:30.000Z"),
        ])
        #expect(summary.gitBranch == "main")
        #expect(summary.model == "gpt-6-sol")
        #expect(summary.effort == "medium")
        #expect(summary.contextTokens == 26_211)
        #expect(summary.contextWindow == 258_400)
        #expect(summary.lastAssistantText == "All **done**.")
        #expect(summary.inferredState == .idle)
        #expect(summary.firstTimestamp == TranscriptParser.parseDate("2026-11-18T00:53:16.044Z"))
        #expect(summary.lastTimestamp == TranscriptParser.parseDate("2026-11-18T00:53:30.000Z"))
    }

    @Test func turnStateAndForkedMeta() {
        let running = parse([
            Codex.rollout("session_meta", nil, ["cwd": "/u/app", "git": ["branch": "feature/sub"]]),
            Codex.rollout("session_meta", nil, ["cwd": "/u/app", "git": ["branch": "parent-branch"]]),
            Codex.rollout("event_msg", "task_started", ["turn_id": "t1"]),
        ])
        #expect(running.gitBranch == "feature/sub")
        #expect(running.inferredState == .running)

        let aborted = parse([
            Codex.rollout("event_msg", "task_started", ["turn_id": "t1"]),
            Codex.rollout("event_msg", "turn_aborted", ["turn_id": "t1", "reason": "interrupted"]),
        ])
        #expect(aborted.inferredState == .idle)
    }

    @Test func updatePlanCallBuildsTasks() {
        let arguments = #"{"plan":[{"step":"A","status":"completed"},{"step":"B","status":"in_progress"}]}"#
        let summary = parse([
            Codex.rollout("response_item", "function_call", ["status": "completed", "name": "update_plan", "arguments": arguments, "call_id": "c1"]),
        ])
        #expect(TaskBook.merged(base: summary.tasks, overlay: TaskBook()).map(\.subject) == ["A", "B"])
    }

    @Test func threadNamesLaterLineWins() {
        let index = """
        {"id":"a","thread_name":"First name","updated_at":"2026-11-15T16:15:49Z"}
        {"id":"b","thread_name":"Other","updated_at":"2026-11-15T16:16:00Z"}
        {"id":"a","thread_name":"Renamed","updated_at":"2026-11-15T17:00:00Z"}
        """
        #expect(CodexFiles.threadNames(fromIndex: Data(index.utf8)) == ["a": "Renamed", "b": "Other"])
    }
}
