import Foundation
import Testing
@testable import AgentLounge

struct SessionReducerTests {
    private func run(_ events: [AgentEvent]) -> AgentSession {
        var session = SessionReducer.newSession(for: events[0])
        for event in events {
            SessionReducer.apply(event, to: &session)
        }
        return session
    }

    @Test func fullTurn() {
        var session = run([TestEvents.event("SessionStart", extra: ["source": "startup", "model": "claude-opus-5-5"])])
        #expect(session.state == .idle)
        #expect(session.model == "claude-opus-5-5")
        #expect(session.projectName == "my-app")
        #expect(session.host == .cmux)
        #expect(session.pid == 800)

        SessionReducer.apply(TestEvents.event("UserPromptSubmit", sentAt: 1_001), to: &session)
        #expect(session.state == .running)

        SessionReducer.apply(TestEvents.event("PreToolUse", sentAt: 1_002, extra: TestEvents.bash("npm test")), to: &session)
        #expect(session.state == .running)
        #expect(session.activity == "Running npm test")

        SessionReducer.apply(TestEvents.event("PermissionRequest", sentAt: 1_003, extra: TestEvents.bash("npm test")), to: &session)
        #expect(session.state == .needsInput)
        #expect(session.attention == "Allow Bash: npm test?")

        SessionReducer.apply(TestEvents.event("PostToolUse", sentAt: 1_004, extra: TestEvents.bash("npm test")), to: &session)
        #expect(session.state == .running)
        #expect(session.attention == nil)

        SessionReducer.apply(TestEvents.event("Stop", sentAt: 1_005, extra: ["last_assistant_message": "All tests pass.\nDetails…"]), to: &session)
        #expect(session.state == .idle)
        #expect(session.activity == nil)
        #expect(session.lastAssistantMessage == "All tests pass.\nDetails…")
        #expect(session.lastEventAt == Date(timeIntervalSince1970: 1_005))
    }

    @Test func notificationsNeedInput() {
        for type in ["permission_prompt", "idle_prompt", "elicitation_dialog"] {
            let session = run([
                TestEvents.event("Stop"),
                TestEvents.event("Notification", extra: ["notification_type": type, "message": "Claude needs you"]),
            ])
            #expect(session.state == .needsInput, "type \(type)")
            #expect(session.attention == "Claude needs you")
        }
        let other = run([TestEvents.event("Stop"), TestEvents.event("Notification", extra: ["notification_type": "auth_success"])])
        #expect(other.state == .idle)
    }

    @Test func repeatedToolFailuresBecomeError() {
        let failure = TestEvents.event("PostToolUseFailure", extra: TestEvents.bash("make").merging(["error": "exit 2\nmore"]) { _, new in new })
        var session = run([TestEvents.event("UserPromptSubmit"), failure, failure])
        #expect(session.state == .running)
        SessionReducer.apply(failure, to: &session)
        #expect(session.state == .error)
        #expect(session.attention == "Bash failed 3 times: exit 2")

        SessionReducer.apply(TestEvents.event("PostToolUse", extra: TestEvents.bash("make")), to: &session)
        #expect(session.state == .running)
        #expect(session.consecutiveToolFailures == 0)
    }

    @Test func stopFailureIsError() {
        let session = run([TestEvents.event("UserPromptSubmit"), TestEvents.event("StopFailure", extra: ["error": "rate_limit"])])
        #expect(session.state == .error)
        #expect(session.attention == "rate_limit")
    }

    @Test func compactStartKeepsRunning() {
        let session = run([
            TestEvents.event("UserPromptSubmit"),
            TestEvents.event("SessionStart", extra: ["source": "compact"]),
        ])
        #expect(session.state == .running)
    }

    @Test func subagentCount() {
        var session = run([TestEvents.event("UserPromptSubmit"), TestEvents.event("SubagentStart"), TestEvents.event("SubagentStart")])
        #expect(session.subagentCount == 2)
        SessionReducer.apply(TestEvents.event("SubagentStop"), to: &session)
        #expect(session.subagentCount == 1)
        SessionReducer.apply(TestEvents.event("Stop"), to: &session)
        #expect(session.subagentCount == 0)
    }

    @Test func lastEventTimeNeverGoesBack() {
        let session = run([TestEvents.event("UserPromptSubmit", sentAt: 2_000), TestEvents.event("PreToolUse", sentAt: 1_500, extra: TestEvents.bash("ls"))])
        #expect(session.lastEventAt == Date(timeIntervalSince1970: 2_000))
    }
}

@MainActor
struct SessionStoreTests {
    @Test func eventCreatesCard() {
        let store = SessionStore()
        store.apply(TestEvents.event("PreToolUse", extra: TestEvents.bash("ls")))
        #expect(store.visibleSessions.count == 1)
        #expect(store.summary == StoreSummary(count: 1, topState: .running))
    }

    @Test func hiddenCardReturnsOnNextEvent() {
        let store = SessionStore()
        store.apply(TestEvents.event("UserPromptSubmit"))
        let id = store.sessions[0].id
        store.hide(id)
        #expect(store.visibleSessions.isEmpty)
        store.apply(TestEvents.event("Stop"))
        #expect(store.visibleSessions.count == 1)
    }

    @Test func deletedCardStaysGoneUntilSessionEnds() {
        let store = SessionStore()
        store.apply(TestEvents.event("UserPromptSubmit"))
        store.delete(store.sessions[0].id)
        store.apply(TestEvents.event("Stop"))
        #expect(store.sessions.isEmpty)

        store.apply(TestEvents.event("SessionEnd"))
        store.apply(TestEvents.event("SessionStart", extra: ["source": "resume"]))
        #expect(store.sessions.count == 1)
    }

    @Test func sessionEndRemovesCard() {
        let store = SessionStore()
        store.apply(TestEvents.event("UserPromptSubmit"))
        store.apply(TestEvents.event("UserPromptSubmit", sessionId: "other"))
        store.apply(TestEvents.event("SessionEnd"))
        #expect(store.sessions.map(\.agentSessionId) == ["other"])
    }

    @Test func summaryPicksMostUrgentState() {
        let store = SessionStore()
        store.apply(TestEvents.event("UserPromptSubmit", sessionId: "a"))
        store.apply(TestEvents.event("Stop", sessionId: "b"))
        store.apply(TestEvents.event("PermissionRequest", sessionId: "c", extra: TestEvents.bash("rm")))
        #expect(store.summary == StoreSummary(count: 3, topState: .needsInput))
    }
}
