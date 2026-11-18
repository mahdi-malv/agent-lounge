import Foundation
import Testing
@testable import AgentLounge

struct ClaudeAdapterTests {
    @Test func mapsCommonFields() {
        let event = TestEvents.event("PreToolUse", extra: TestEvents.bash("npm test"))
        #expect(event.agent == .claude)
        #expect(event.sessionId == TestEvents.sessionId)
        #expect(event.cardID == "claude:\(TestEvents.sessionId)")
        #expect(event.cwd == "/Users/u/code/my-app")
        #expect(event.permissionMode == "default")
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_000))
        #expect(event.kind == .preToolUse(ToolCall(name: "Bash", input: .object(["command": .string("npm test")]), useId: "toolu_1")))
    }

    @Test func mapsEventKinds() {
        #expect(TestEvents.event("SessionStart", extra: ["source": "startup"]).kind == .sessionStart(source: "startup"))
        #expect(TestEvents.event("UserPromptSubmit", extra: ["prompt": "hi"]).kind == .userPromptSubmit)
        #expect(TestEvents.event("Stop", extra: ["last_assistant_message": "Done."]).kind == .stop(lastMessage: "Done."))
        #expect(TestEvents.event("SessionEnd", extra: ["reason": "exit"]).kind == .sessionEnd(reason: "exit"))
        #expect(TestEvents.event("SomethingNew").kind == .unknown("SomethingNew"))
        #expect(
            TestEvents.event("Notification", extra: ["notification_type": "idle_prompt", "message": "Waiting"]).kind
                == .notification(type: "idle_prompt", message: "Waiting")
        )
    }

    @Test func readsModelAsStringOrObject() {
        #expect(TestEvents.event("SessionStart", extra: ["model": "claude-opus-5-5"]).model == "claude-opus-5-5")
        #expect(TestEvents.event("SessionStart", extra: ["model": ["id": "claude-sonnet-5-5"]]).model == "claude-sonnet-5-5")
    }

    @Test func rejectsPayloadWithoutSessionId() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "v": 1, "source": "claude", "host": [:] as [String: Any],
            "payload": ["hook_event_name": "Stop"],
        ])
        let envelope = try JSONDecoder().decode(HookEnvelope.self, from: data)
        #expect(ClaudeAdapter.event(from: envelope, receivedAt: .now) == nil)
    }

    @Test func detectsHosts() {
        #expect(HostInfo(bundleId: "com.cmuxterm.app", cmuxSurfaceId: "S").hostKind == .cmux)
        #expect(HostInfo(termProgram: "zed", zedTerm: "true").hostKind == .zed)
        #expect(HostInfo(bundleId: "com.anthropic.claudefordesktop").hostKind == .claudeApp)
        #expect(HostInfo(termProgram: "Apple_Terminal").hostKind == .terminal("Terminal"))
        #expect(HostInfo(termProgram: "ghostty").hostKind == .terminal("Ghostty"))
        #expect(HostInfo().hostKind == .unknown)
        // Process tree beats inherited env.
        let zedFromCmux = HostInfo(
            termProgram: "zed", bundleId: "com.cmuxterm.app", cmuxSurfaceId: "S", zedTerm: "true",
            processes: [
                ProcessEntry(pid: 30, ppid: 20, name: "zsh", path: "/bin/zsh"),
                ProcessEntry(pid: 20, ppid: 10, name: "login", path: "/usr/bin/login"),
                ProcessEntry(pid: 10, ppid: 1, name: "zed", path: "/Applications/Zed.app/Contents/MacOS/zed"),
            ]
        )
        #expect(zedFromCmux.hostKind == .zed)
        let desktop = HostInfo(processes: [
            ProcessEntry(pid: 30, ppid: 20, name: "claude", path: "/Users/u/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude"),
            ProcessEntry(pid: 20, ppid: 10, name: "disclaimer", path: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            ProcessEntry(pid: 10, ppid: 1, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ])
        #expect(desktop.hostKind == .claudeApp)
        // Without a process tree: the terminal's own markers beat an inherited bundle id.
        #expect(HostInfo(termProgram: "zed", bundleId: "com.cmuxterm.app", zedTerm: "true").hostKind == .zed)
        #expect(HostInfo(termProgram: "Apple_Terminal", bundleId: "com.mitchellh.ghostty").hostKind == .terminal("Terminal"))
        #expect(HostInfo(bundleId: "com.mitchellh.ghostty").hostKind == .terminal("Ghostty"))
    }

    @Test func findsAgentPIDByVersionedPath() {
        let event = TestEvents.event("Stop")
        #expect(event.host.agentPID(for: .claude) == 800)
        #expect(event.host.tty == "ttys002")
    }
}
