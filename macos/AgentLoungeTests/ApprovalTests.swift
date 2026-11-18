import Foundation
import Testing
@testable import AgentLounge

struct ApprovalRulesTests {
    private func approval(_ card: String = "claude:\(TestEvents.sessionId)", agentId: String? = nil) -> PendingApproval {
        PendingApproval(
            id: UUID().uuidString, cardID: card, agentId: agentId, toolName: "Bash", toolInput: nil,
            title: "Running rm", detail: "rm x", createdAt: .now
        )
    }

    @Test func toolsThatNeedAnAnswerAreNotHeld() {
        #expect(ApprovalRules.canHold(ToolCall(name: "Bash")))
        #expect(!ApprovalRules.canHold(ToolCall(name: "AskUserQuestion")))
        #expect(!ApprovalRules.canHold(ToolCall(name: "ExitPlanMode")))
    }

    @Test func hookOutputShape() throws {
        let allow = try JSONSerialization.jsonObject(with: ApprovalRules.hookOutput(allow: true)) as! [String: Any]
        let output = allow["hookSpecificOutput"] as! [String: Any]
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        #expect((output["decision"] as! [String: Any])["behavior"] as? String == "allow")
        #expect((output["decision"] as! [String: Any])["message"] == nil)

        let deny = try JSONSerialization.jsonObject(with: ApprovalRules.hookOutput(allow: false)) as! [String: Any]
        let decision = (deny["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        #expect(decision["behavior"] as? String == "deny")
        #expect((decision["message"] as? String)?.isEmpty == false)
    }

    @Test func laterEventsReleaseTheRightRequests() {
        let main = approval()
        let sub = approval(agentId: "agent-1")
        let other = approval("claude:other")
        let all = [main, sub, other]

        let post = TestEvents.event("PostToolUse", extra: TestEvents.bash("rm x"))
        #expect(ApprovalRules.resolved(by: post, among: all) == [main])

        let subPre = TestEvents.event("PreToolUse", extra: TestEvents.bash("ls").merging(["agent_id": "agent-1"]) { $1 })
        #expect(ApprovalRules.resolved(by: subPre, among: all) == [sub])

        let stop = TestEvents.event("Stop", extra: ["last_assistant_message": "ok"])
        #expect(ApprovalRules.resolved(by: stop, among: all) == [main, sub])

        // The Notification that follows the dialog (~6 s) must not release it.
        let notification = TestEvents.event("Notification", extra: ["notification_type": "permission_prompt"])
        #expect(ApprovalRules.resolved(by: notification, among: all).isEmpty)
        let permission = TestEvents.event("PermissionRequest", extra: TestEvents.bash("rm y"))
        #expect(ApprovalRules.resolved(by: permission, among: all).isEmpty)
    }

    @Test func detailIsCut() {
        let long = String(repeating: "a", count: PendingApproval.maxDetail + 50)
        let detail = ApprovalRules.detail(of: ToolCall(name: "Bash", input: .object(["command": .string(long)])))
        #expect(detail?.count == PendingApproval.maxDetail + 1)
        #expect(ApprovalRules.detail(of: ToolCall(name: "Bash")) == nil)
    }
}

struct ApprovalCenterTests {
    @Test func holdDecideAndRelease() {
        let center = ApprovalCenter()
        var enabled = false
        center.isEnabled = { enabled }
        let event = TestEvents.event("PermissionRequest", extra: TestEvents.bash("rm x"))
        guard case .permissionRequest(let tool) = event.kind else {
            Issue.record("not a permission request")
            return
        }

        var responses: [HTTPResponse] = []
        func responder() -> HTTPResponder { HTTPResponder { responses.append($0) } }

        #expect(!center.hold(event, tool: tool, responder: responder()))
        enabled = true
        #expect(center.hold(event, tool: tool, responder: responder()))
        let id = center.pending[0].id
        #expect(center.first(for: event.cardID)?.title == "Running rm x")

        #expect(center.decide(id, allow: true, by: "Pixel"))
        #expect(!center.decide(id, allow: false, by: "Pixel"))
        #expect(responses.count == 1 && responses[0].status == 200)
        #expect(String(decoding: responses[0].body, as: UTF8.self).contains(#""behavior":"allow""#))

        // Answered on the Mac: the next tool event releases it without a decision.
        #expect(center.hold(event, tool: tool, responder: responder()))
        center.eventArrived(TestEvents.event("PostToolUse", extra: TestEvents.bash("rm x")))
        #expect(center.pending.isEmpty)
        #expect(responses.last?.status == 204)
    }

    @Test func hookGoneDropsTheRequest() {
        let center = ApprovalCenter()
        center.isEnabled = { true }
        let event = TestEvents.event("PermissionRequest", extra: TestEvents.bash("rm x"))
        guard case .permissionRequest(let tool) = event.kind else { return }
        let responder = HTTPResponder { _ in }
        #expect(center.hold(event, tool: tool, responder: responder))
        responder.onClientGone?()
        #expect(center.pending.isEmpty)
    }
}

struct ApprovalProtocolTests {
    @Test func decideMessageAndCardField() throws {
        let decide = try RemoteCoding.decoder.decode(
            ClientMessage.self,
            from: Data(#"{"type":"decide","requestId":"r1","allow":false}"#.utf8)
        )
        #expect(decide.type == .decide && decide.requestId == "r1" && decide.allow == false)

        var book = PairingBook()
        let early = RemoteHandshake.handle(Data(#"{"type":"decide","v":2,"requestId":"r1","allow":true}"#.utf8),
                                           book: &book, server: "Mac", serverId: "s", now: .now)
        if case .reply(let message, let close) = early {
            #expect(close && message.error == .badMessage)
        } else {
            Issue.record("expected a refusal")
        }

        let session = AgentSession(id: "claude:s", agent: .claude, host: .unknown, state: .needsInput, cwd: "/a",
                                   startedAt: .now, lastEventAt: .now)
        let pending = PendingApproval(id: "r1", cardID: "claude:s", agentId: nil, toolName: "Bash", toolInput: nil,
                                      title: "Running rm", detail: "rm x", createdAt: .now)
        let card = RemoteCard(session, approval: pending)
        #expect(card.approval == RemoteApproval(id: "r1", tool: "Bash", title: "Running rm", detail: "rm x"))
        #expect(RemoteAlert(.needsInput, session: session, approval: pending).approval?.id == "r1")
        #expect(RemoteAlert(.done, session: session, approval: pending).approval == nil)
    }
}

struct ApprovalInstallerTests {
    private let command = HookConfig.command(hookPath: "/A/lounge-hook", agent: .claude)

    @Test func permissionRequestGetsTheLongTimeout() throws {
        let config = HookConfig.claude.installed(.emptyObject, command: command)
        let handler = config["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first
        #expect(handler?["timeout"]?.numberText == String(HookConfig.approvalTimeoutSeconds))
        let stop = config["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first
        #expect(stop?["timeout"]?.numberText == "5")
        #expect(HookConfig.claude.status(of: config, command: command) == .installed)
    }

    @Test func oldTimeoutIsOutdated() throws {
        var config = HookConfig.claude.installed(.emptyObject, command: command)
        var hooks = config["hooks"]!
        var group = hooks["PermissionRequest"]!.arrayValue!.first!
        var handler = group["hooks"]!.arrayValue!.first!
        handler["timeout"] = .number("5")
        group["hooks"] = .array([handler])
        hooks["PermissionRequest"] = .array([group])
        config["hooks"] = hooks
        #expect(HookConfig.claude.status(of: config, command: command) == .outdated)
        // Codex keeps 5 s everywhere: its hooks may run before its own prompt.
        let codex = HookConfig.codex.installed(.emptyObject, command: command)
        #expect(codex["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["timeout"]?.numberText == "5")
    }
}

struct PromptPlanTests {
    private func session(host: HostKind, tty: String? = "ttys012", state: SessionState = .idle) -> AgentSession {
        var session = AgentSession(id: "claude:s", agent: .claude, host: host, state: state, cwd: "/a", startedAt: .now, lastEventAt: .now)
        if let tty { session.hostInfo = HostInfo(tty: tty) }
        return session
    }

    @Test func onlyGhosttyWithTTY() {
        #expect(PromptPlan.plan(for: session(host: .terminal("Ghostty")), text: "run tests") == .ghostty(tty: "/dev/ttys012", text: "run tests"))
        #expect(PromptPlan.canPrompt(session(host: .terminal("Ghostty"))))
        #expect(!PromptPlan.canPrompt(session(host: .terminal("Ghostty"), tty: nil)))
        #expect(!PromptPlan.canPrompt(session(host: .zed)))
        #expect(PromptPlan.plan(for: session(host: .claudeApp), text: "x") == .refused("Prompts work only for sessions in Ghostty."))
        #expect(PromptPlan.plan(for: nil, text: "x") == .refused("The session has ended."))
    }

    @Test func refusedWhileADialogIsOpen() {
        if case .refused = PromptPlan.plan(for: session(host: .terminal("Ghostty"), state: .needsInput), text: "yes") {} else {
            Issue.record("must refuse while the agent waits for a dialog answer")
        }
    }

    @Test func cleaningAndEscaping() {
        #expect(PromptPlan.clean("  hi\u{1b}[31m\r\nthere\u{7}\n\n") == "hi[31m\nthere")
        #expect(PromptPlan.clean(String(repeating: "a", count: 5_000)).count == PromptPlan.maxLength)
        if case .refused = PromptPlan.plan(for: session(host: .terminal("Ghostty")), text: " \n ") {} else {
            Issue.record("empty prompt must be refused")
        }
        #expect(PromptPlan.literal(#"say "hi" \ now"# + "\nnext\tend") == #""say \"hi\" \\ now\nnext\tend""#)
        let script = PromptPlan.appleScript(tty: "/dev/ttys012", text: #"a"b"#)
        #expect(script.contains(#"input text "a\"b" to t"#))
        #expect(script.contains(#"first terminal whose tty is "/dev/ttys012""#))
    }
}
