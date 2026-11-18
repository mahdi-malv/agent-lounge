import Darwin
import Foundation
import Testing
@testable import AgentLounge

/// Lines shaped like real Claude Code 2.1.x transcript entries (compact JSON).
private enum Lines {
    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func assistant(
        _ content: [[String: Any]],
        stop: String? = "end_turn",
        model: String = "claude-opus-5-5",
        tokens: (Int, Int, Int) = (2, 100, 50_000),
        sidechain: Bool = false,
        time: String = "2026-11-18T10:00:05.000Z"
    ) -> String {
        var message: [String: Any] = [
            "model": model, "role": "assistant", "content": content,
            "usage": ["input_tokens": tokens.0, "cache_creation_input_tokens": tokens.1, "cache_read_input_tokens": tokens.2, "output_tokens": 10],
        ]
        message["stop_reason"] = stop ?? NSNull()
        // Real lines start with parentUuid/isSidechain; keep that order for the byte markers.
        let head = "{\"parentUuid\":\"p\",\"isSidechain\":\(sidechain),"
        let rest = line(["message": message, "type": "assistant", "gitBranch": "feature/x", "effort": "high", "timestamp": time])
        return head + rest.dropFirst()
    }

    static func user(_ content: Any, toolUseResult: [String: Any]? = nil, time: String = "2026-11-18T10:00:00.000Z") -> String {
        var object: [String: Any] = ["message": ["role": "user", "content": content], "type": "user", "timestamp": time]
        if let toolUseResult { object["toolUseResult"] = toolUseResult }
        return "{\"parentUuid\":\"p\",\"isSidechain\":false," + line(object).dropFirst()
    }

    static func taskCreate(id: String, subject: String) -> [[String: Any]] {
        [["type": "tool_use", "id": "toolu_\(id)", "name": "TaskCreate", "input": ["subject": subject, "activeForm": "\(subject)ing"]]]
    }

    static func taskResult(id: String, subject: String) -> String {
        user([["type": "tool_result", "tool_use_id": "toolu_\(id)", "content": "ok"]], toolUseResult: ["task": ["id": id, "subject": subject]])
    }
}

struct TranscriptParserTests {
    private func parse(_ lines: [String], chunk: Int? = nil) -> TranscriptSummary {
        var parser = TranscriptParser()
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let chunk {
            var index = 0
            while index < data.count {
                parser.consume(data.subdata(in: index..<min(index + chunk, data.count)))
                index += chunk
            }
        } else {
            parser.consume(data)
        }
        return parser.summary
    }

    private var sample: [String] {
        [
            #"{"type":"ai-title","aiTitle":"Fix the checkout","sessionId":"s"}"#,
            Lines.user("Fix the checkout bug"),
            Lines.assistant(Lines.taskCreate(id: "1", subject: "Read code"), stop: "tool_use"),
            Lines.taskResult(id: "1", subject: "Read code"),
            Lines.assistant([["type": "tool_use", "id": "toolu_u", "name": "TaskUpdate", "input": ["taskId": "1", "status": "completed"]]], stop: "tool_use"),
            Lines.assistant([["type": "text", "text": "Sub work"]], model: "claude-haiku-5-5", tokens: (1, 1, 999_999), sidechain: true),
            Lines.assistant([["type": "text", "text": "Fixed it."]], tokens: (3, 200, 60_000), time: "2026-11-18T10:05:00.000Z"),
            #"{"type":"file-history-delta","messageId":"m"}"#,
        ]
    }

    @Test func extractsFacts() {
        let summary = parse(sample)
        #expect(summary.aiTitle == "Fix the checkout")
        #expect(summary.model == "claude-opus-5-5")
        #expect(summary.effort == "high")
        #expect(summary.gitBranch == "feature/x")
        #expect(summary.contextTokens == 60_203)
        #expect(summary.peakContextTokens == 60_203) // Sidechain ignored.
        #expect(summary.lastAssistantText == "Fixed it.")
        #expect(summary.inferredState == .idle)
        #expect(summary.firstTimestamp == TranscriptParser.parseDate("2026-11-18T10:00:00.000Z"))
        #expect(summary.lastTimestamp == TranscriptParser.parseDate("2026-11-18T10:05:00.000Z"))

        let tasks = TaskBook.merged(base: summary.tasks, overlay: TaskBook())
        #expect(tasks.map(\.subject) == ["Read code"])
        #expect(tasks.first?.status == .completed)
        #expect(tasks.first?.activeForm == "Read codeing")
    }

    @Test func permissionModeFromUserEntries() {
        let line = #"{"parentUuid":"p","isSidechain":false,"message":{"role":"user","content":"hi"},"permissionMode":"auto","type":"user","timestamp":"2026-11-18T10:00:00.000Z"}"#
        #expect(parse([line]).permissionMode == "auto")
    }

    @Test func sameResultInSmallChunks() {
        #expect(parse(sample, chunk: 7) == parse(sample))
    }

    @Test func runningWhileToolResultIsLast() {
        let summary = parse([Lines.user("Go"), Lines.assistant([["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "ls"]]], stop: "tool_use")])
        #expect(summary.inferredState == .running)
    }

    @Test func interruptIsIdle() {
        let summary = parse([Lines.user("Go"), Lines.user([["type": "text", "text": "[Request interrupted by user]"]])])
        #expect(summary.inferredState == .idle)
    }

    @Test func midFileStartDropsPartialLine() {
        var parser = TranscriptParser(startsMidFile: true)
        parser.consume(Data(("odel\":\"broken\"}\n" + #"{"type":"ai-title","aiTitle":"Tail","sessionId":"s"}"# + "\n").utf8))
        #expect(parser.summary.aiTitle == "Tail")
        #expect(parser.summary.isComplete == false)
    }

    @Test func readerReadsOnlyNewBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lounge-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((Lines.user("Go") + "\n").utf8).write(to: url)

        let reader = TranscriptReader()
        let first = await reader.read(path: url.path, format: .claude)
        #expect(first?.inferredState == .running)
        #expect(await reader.read(path: url.path, format: .claude) == nil) // No change.

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Lines.assistant([["type": "text", "text": "Done"]]) + "\n").utf8))
        try handle.close()
        let second = await reader.read(path: url.path, format: .claude)
        #expect(second?.lastAssistantText == "Done")
        #expect(second?.inferredState == .idle)
    }
}

struct SystemTests {
    @Test func ownEnvironment() throws {
        let environment = try #require(ProcessInspector.environment(getpid()))
        #expect(environment["PATH"] != nil)
    }

    @Test func parsesProcArgs() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes.append(contentsOf: $0) }
        for part in ["/bin/claude", "", "", "claude", "--resume", "A=1", "TERM_PROGRAM=ghostty", "B=x=y", ""] {
            bytes.append(contentsOf: Array(part.utf8) + [0])
        }
        let parsed = try #require(ProcessInspector.parseProcArgs(bytes))
        #expect(parsed.arguments == ["claude", "--resume"])
        #expect(parsed.environment == ["A": "1", "TERM_PROGRAM": "ghostty", "B": "x=y"])
    }

    @Test func ownProcessInfo() throws {
        let info = try #require(ProcessInspector.info(getpid()))
        #expect(ProcessInspector.isAlive(getpid(), startTime: info.startTime))
        #expect(!ProcessInspector.isAlive(getpid(), startTime: info.startTime - 100))
        #expect(ProcessInspector.ancestry(from: getpid()).last?.pid == 1)
    }

    @Test func procStartFormat() throws {
        let date = try #require(ClaudeFiles.parseProcStart("Wed Nov  5 09:01:02 2026"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.day, .hour, .minute], from: date)
        #expect(parts.day == 5 && parts.hour == 9 && parts.minute == 1)
    }

    @Test func hostInfoFromEnvironment() {
        let host = HostInfo(
            environment: ["CMUX_SURFACE_ID": "S", "TERM_PROGRAM": "ghostty", "__CFBundleIdentifier": "com.cmuxterm.app"],
            processes: [ProcessEntry(pid: 5, ppid: 1, name: "2.1.327", path: "/u/.local/share/claude/versions/2.1.327", tty: "ttys009")]
        )
        #expect(host.hostKind == .cmux)
        #expect(host.tty == "ttys009")
        #expect(host.agentPID(for: .claude) == 5)
        #expect(HostInfo(environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"], processes: []).hostKind == .claudeApp)
    }
}
