import Foundation
import Testing
@testable import AgentLounge

struct AlertRuleTests {
    private let stop = AgentEvent.Kind.stop(lastMessage: "ok")

    @Test func needsInputAndErrorOnEntry() {
        let permission = AgentEvent.Kind.permissionRequest(ToolCall(name: "Bash"))
        #expect(AlertRule.alert(for: permission, before: .running, after: .needsInput) == .needsInput)
        #expect(AlertRule.alert(for: permission, before: nil, after: .needsInput) == .needsInput)
        #expect(AlertRule.alert(for: .notification(type: "permission_prompt", message: nil), before: .needsInput, after: .needsInput) == nil)
        #expect(AlertRule.alert(for: .stopFailure(error: "x"), before: .running, after: .error) == .error)
        #expect(AlertRule.alert(for: .stopFailure(error: "x"), before: .error, after: .error) == nil)
    }

    @Test func doneOnlyAfterAFinishedTurn() {
        #expect(AlertRule.alert(for: stop, before: .running, after: .idle) == .done)
        #expect(AlertRule.alert(for: stop, before: .needsInput, after: .idle) == .done)
        #expect(AlertRule.alert(for: stop, before: .idle, after: .idle) == nil)
        #expect(AlertRule.alert(for: stop, before: nil, after: .idle) == nil)
        #expect(AlertRule.alert(for: .interrupt, before: .running, after: .idle) == nil)
        #expect(AlertRule.alert(for: .sessionStart(source: "startup"), before: .running, after: .idle) == nil)
        #expect(AlertRule.alert(for: .userPromptSubmit, before: .idle, after: .running) == nil)
    }

    @Test func storeTransitionsFromHookEvents() {
        let store = SessionStore()
        var kinds: [AlertKind] = []
        func apply(_ name: String, _ extra: [String: Any] = [:]) {
            let event = TestEvents.event(name, extra: extra)
            let before = store.session(event.cardID)?.state
            store.apply(event)
            if let kind = AlertRule.alert(for: event.kind, before: before, after: store.session(event.cardID)!.state) {
                kinds.append(kind)
            }
        }
        apply("SessionStart", ["source": "startup"])
        apply("UserPromptSubmit")
        apply("PreToolUse", TestEvents.bash("ls"))
        apply("PermissionRequest", TestEvents.bash("rm x"))
        apply("Notification", ["notification_type": "permission_prompt"])
        apply("PostToolUse", TestEvents.bash("rm x"))
        apply("Stop", ["last_assistant_message": "Done."])
        #expect(kinds == [.needsInput, .done])
    }

    @Test func messages() {
        var session = AgentSession(id: "claude:s", agent: .claude, host: .unknown, state: .idle, cwd: "/a", startedAt: .now, lastEventAt: .now)
        #expect(AlertRule.message(for: .done, session: session) == "Finished the turn")
        session.lastAssistantMessage = "\nAll tests pass.\nMore text"
        #expect(AlertRule.message(for: .done, session: session) == "All tests pass.")
        session.attention = "Allow Bash: rm x?"
        #expect(AlertRule.message(for: .needsInput, session: session) == "Allow Bash: rm x?")
    }
}

struct AutoHideTests {
    private func session(_ id: String, _ state: SessionState, minutesAgo: Double, now: Date) -> AgentSession {
        let time = now.addingTimeInterval(-minutesAgo * 60)
        return AgentSession(id: id, agent: .claude, host: .unknown, state: state, cwd: "/a", startedAt: time, lastEventAt: time)
    }

    @Test func hidesOldIdleCardsOnly() {
        let now = Date(timeIntervalSince1970: 10_000)
        let sessions = [
            session("old-idle", .idle, minutesAgo: 16, now: now),
            session("new-idle", .idle, minutesAgo: 3, now: now),
            session("old-running", .running, minutesAgo: 30, now: now),
            session("old-input", .needsInput, minutesAgo: 30, now: now),
        ]
        #expect(AutoHide.expiredIDs(sessions, minutes: 15, now: now) == ["old-idle"])
        #expect(AutoHide.expiredIDs(sessions, minutes: 0, now: now).isEmpty)
    }

    @Test func hiddenCardReturnsOnNextEvent() {
        let store = SessionStore()
        store.apply(TestEvents.event("Stop"))
        let id = store.sessions[0].id
        store.hide(id)
        #expect(store.visibleSessions.isEmpty)
        store.apply(TestEvents.event("UserPromptSubmit"))
        #expect(store.visibleSessions.map(\.id) == [id])
    }
}

struct SourceFilterTests {
    @Test func sourcePerSession() {
        let base = AgentSession(id: "x", agent: .claude, host: .terminal("Ghostty"), state: .idle, cwd: "/a", startedAt: .now, lastEventAt: .now)
        var app = base
        app.host = .claudeApp
        var codex = base
        codex.agent = .codex
        codex.host = .codexApp
        #expect(base.source == .claudeCLI)
        #expect(app.source == .claudeApp)
        #expect(codex.source == .codex)
    }

    @Test func disabledSourceIsHiddenButKept() {
        let store = SessionStore()
        store.apply(TestEvents.event("UserPromptSubmit"))
        store.disabledSources = [.claudeCLI]
        #expect(store.visibleSessions.isEmpty)
        #expect(store.summary.count == 0)
        #expect(store.sessions.count == 1)
        store.disabledSources = []
        #expect(store.visibleSessions.count == 1)
    }
}

struct PreferencesTests {
    private func makeDefaults() -> UserDefaults {
        let name = "AgentLoungeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsWhenEmpty() {
        let preferences = Preferences(defaults: makeDefaults())
        #expect(preferences.floatsWhenPinned)
        #expect(preferences.autoHideDoneMinutes == 0)
        #expect(preferences.enabledSources == Set(SessionSource.allCases))
        #expect(preferences.alert(.needsInput) == Preferences.defaultAlerts[.needsInput])
        #expect(preferences.alert(.done).showsNotification == false)
        #expect(preferences.notchEnabled == false)
        #expect(preferences.notchPlacement == .mouse)
    }

    @Test func valuesSurviveReload() {
        let defaults = makeDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.floatsWhenPinned = false
        preferences.autoHideDoneMinutes = 30
        preferences.isMuted = true
        preferences.setEnabled(.codex, false)
        preferences.setAlert(.done) { $0.soundName = "Hero"; $0.showsNotification = true }
        preferences.notchEnabled = true
        preferences.notchPlacement = .allScreens

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.floatsWhenPinned == false)
        #expect(reloaded.autoHideDoneMinutes == 30)
        #expect(reloaded.isMuted)
        #expect(reloaded.enabledSources == [.claudeCLI, .claudeApp])
        #expect(reloaded.alert(.done) == AlertSetting(playsSound: true, soundName: "Hero", showsNotification: true))
        #expect(reloaded.alert(.error) == Preferences.defaultAlerts[.error])
        #expect(reloaded.notchEnabled)
        #expect(reloaded.notchPlacement == .allScreens)
    }
}
