import Foundation
import Testing
@testable import AgentLounge

private enum Antigravity {
    static let conversationId = "269f07d1-3064-46c4-80d7-3cea96b705ed"

    static let ghosttyHost: [String: Any] = [
        "termProgram": "ghostty",
        "bundleId": "com.mitchellh.ghostty",
        "tty": "ttys004",
        "processes": [
            ["pid": 700, "ppid": 400, "name": "agy", "path": "/Users/test/.local/bin/agy"],
            ["pid": 400, "ppid": 300, "name": "zsh", "path": "/bin/zsh", "tty": "ttys004"],
            ["pid": 200, "ppid": 1, "name": "ghostty", "path": "/Applications/Ghostty.app/Contents/MacOS/ghostty"],
        ],
    ]

    static func event(
        _ name: String,
        host: [String: Any] = ghosttyHost,
        sentAt: Double = 2_000,
        extra: [String: Any] = [:]
    ) -> AgentEvent {
        var payload: [String: Any] = [
            "conversationId": conversationId,
            "hookEventName": name,
            "workspacePaths": ["/u/project"],
            "cwd": "/u/project",
            "modelName": "auto",
            "transcriptPath": "/u/.gemini/antigravity-cli/brain/\(conversationId)/.system_generated/logs/transcript.jsonl",
        ]
        payload.merge(extra) { _, new in new }
        let body: [String: Any] = [
            "v": 1,
            "source": "antigravity",
            "sentAt": sentAt,
            "host": host,
            "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let envelope = try! JSONDecoder().decode(HookEnvelope.self, from: data)
        return AntigravityAdapter.event(from: envelope, receivedAt: Date(timeIntervalSince1970: sentAt))!
    }
}

struct AntigravityAdapterTests {
    @Test func mapsLifecycleEvents() {
        let start = Antigravity.event("SessionStart")
        #expect(start.agent == .antigravity)
        #expect(start.cardID == "antigravity:\(Antigravity.conversationId)")
        #expect(start.kind == .sessionStart(source: nil))
        #expect(start.model == nil) // "auto" is ignored so transcript model wins
        #expect(start.cwd == "/u/project")

        let preInvoke = Antigravity.event("PreInvocation", extra: ["modelName": "gemini-4-neon-medium"])
        #expect(preInvoke.kind == .userPromptSubmit)
        #expect(preInvoke.model == "gemini-4-neon-medium")

        let preTool = Antigravity.event("PreToolUse", extra: [
            "toolCall": ["id": "call-1", "name": "run_command", "args": ["CommandLine": "make test", "toolSummary": "Run unit tests"]],
        ])
        #expect(preTool.kind == .preToolUse(ToolCall(
            name: "run_command",
            input: .object(["CommandLine": .string("make test"), "toolSummary": .string("Run unit tests")]),
            useId: "call-1"
        )))

        let postOk = Antigravity.event("PostToolUse", extra: [
            "toolCall": ["id": "call-1", "name": "run_command", "args": ["CommandLine": "make test"]],
        ])
        if case .postToolUse(let tool) = postOk.kind {
            #expect(tool.name == "run_command")
        } else {
            Issue.record("Expected postToolUse")
        }

        let postErr = Antigravity.event("PostToolUse", extra: [
            "toolCall": ["id": "call-1", "name": "run_command", "args": ["CommandLine": "make test"]],
            "error": "exit status 1",
        ])
        if case .postToolUseFailure(let tool, let error) = postErr.kind {
            #expect(tool.name == "run_command")
            #expect(error == "exit status 1")
        } else {
            Issue.record("Expected postToolUseFailure")
        }

        #expect(Antigravity.event("Stop", extra: ["terminationReason": "NO_TOOL_CALL"]).kind == .stop(lastMessage: nil))
        #expect(Antigravity.event("Stop", extra: ["terminationReason": "USER_CANCELED"]).kind == .interrupt)
        #expect(Antigravity.event("Stop", extra: ["terminationReason": "ERROR", "error": "rate limited"]).kind == .stopFailure(error: "rate limited"))
    }

    @Test func storeRunsAFullTurn() {
        let store = SessionStore()
        store.apply(Antigravity.event("SessionStart", sentAt: 2_000))
        store.apply(Antigravity.event("PreInvocation", sentAt: 2_001))
        store.apply(Antigravity.event("PreToolUse", sentAt: 2_002, extra: [
            "toolCall": ["id": "t1", "name": "edit_file", "args": ["Path": "/u/project/App.swift"]],
        ]))
        var card = store.session("antigravity:\(Antigravity.conversationId)")!
        #expect(card.state == .running)
        #expect(card.activity == "Editing App.swift")
        #expect(card.pid == 700)
        #expect(card.host == .terminal("Ghostty"))
        #expect(card.source == .antigravity)

        store.apply(Antigravity.event("PreToolUse", sentAt: 2_003, extra: [
            "toolCall": [
                "id": "t2",
                "name": "ask_question",
                "args": ["questions": [["question": "Deploy now?"]]],
            ],
        ]))
        card = store.session(card.id)!
        #expect(card.state == .needsInput)
        #expect(card.attention == "Deploy now?")

        store.apply(Antigravity.event("Stop", sentAt: 2_004, extra: ["terminationReason": "NO_TOOL_CALL"]))
        card = store.session(card.id)!
        #expect(card.state == .idle)
        #expect(card.activity == nil)
    }

    @Test func updateStepsBuildsTasks() {
        var book = TaskBook()
        let args: JSONValue = .object(["steps": .array([
            .object(["title": .string("Inspect repo"), "status": .string("done")]),
            .object(["title": .string("Implement hooks"), "status": .string("in_progress")]),
            .object(["title": .string("Run tests"), "status": .string("pending")]),
        ])])
        let handled = book.apply(toolName: "update_steps", input: args, response: nil)
        #expect(handled)
        let tasks = TaskBook.merged(base: TaskBook(), overlay: book)
        #expect(tasks.map(\.subject) == ["Inspect repo", "Implement hooks", "Run tests"])
        #expect(tasks.map(\.status) == [.completed, .inProgress, .pending])
    }
}

struct AntigravityTranscriptTests {
    @Test func parsesPlannerAndUserLines() {
        let lines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-25T17:50:17Z","content":"hello"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T17:50:18Z","model":"gemini-4-neon-medium","input_tokens":16485,"cache_read_tokens":0,"output_tokens":346,"tool_calls":[{"name":"run_command"}]}"#,
            #"{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-25T17:50:20Z","content":"ignored tool output"}"#,
            #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T17:50:25Z","model":"gemini-4-neon-medium","input_tokens":2485,"cache_read_tokens":17689,"output_tokens":200,"content":"All done!"}"#,
        ]
        var parser = AntigravityTranscriptParser()
        parser.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        let summary = parser.summary
        #expect(summary.model == "gemini-4-neon-medium")
        #expect(summary.contextTokens == 2_485 + 17_689)
        #expect(summary.contextWindow == ContextWindow.extended)
        #expect(summary.lastAssistantText == "All done!")
        #expect(summary.inferredState == .idle)
        #expect(summary.firstTimestamp == TranscriptParser.parseDate("2026-11-25T17:50:17Z"))
        #expect(summary.lastTimestamp == TranscriptParser.parseDate("2026-11-25T17:50:25Z"))
    }
}

struct AntigravityHookConfigTests {
    private let command = HookConfig.command(hookPath: "/Apps/Agent Lounge.app/Contents/Resources/bin/lounge-hook", agent: .antigravity)

    @Test func installPreservesOtherNamedHooks() throws {
        let beforeText = """
        {
          "cmux": {
            "Stop": [
              { "type": "command", "command": "cmux stop", "timeout": 10 }
            ]
          }
        }
        """
        let before = try OrderedJSON.parse(Data(beforeText.utf8))
        let config = HookConfig.antigravity
        #expect(config.status(of: before, command: command) == .notInstalled)

        let after = config.installed(before, command: command)
        #expect(config.status(of: after, command: command) == .installed)
        #expect(after["cmux"] == before["cmux"])
        // Flat handler for SessionStart / PreInvocation / Stop.
        #expect(after["agent-lounge"]?["Stop"]?.arrayValue?.first?["command"]?.stringValue == command)
        // Grouped handler with matcher for PreToolUse / PostToolUse.
        #expect(after["agent-lounge"]?["PreToolUse"]?.arrayValue?.first?["matcher"]?.stringValue == "*")
        #expect(after["agent-lounge"]?["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue == command)

        // Idempotent install and clean uninstall.
        #expect(config.installed(after, command: command) == after)
        #expect(config.uninstalled(after) == before)

        // Different path → outdated.
        #expect(config.status(of: after, command: "'/other/lounge-hook' antigravity") == .outdated)
    }
}
