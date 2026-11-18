import Foundation
import Testing
@testable import AgentLounge

struct FocusRouteTests {
    private func session(host: HostInfo, cwd: String = "/Users/u/code/my-app", appSessionId: String? = nil) -> AgentSession {
        var session = AgentSession(
            id: "claude:s1", agent: .claude, host: host.hostKind, state: .running,
            cwd: cwd, startedAt: .now, lastEventAt: .now, hostInfo: host
        )
        session.appSessionId = appSessionId
        return session
    }

    @Test func ghosttyUsesTTY() {
        let host = HostInfo(termProgram: "ghostty", bundleId: "com.mitchellh.ghostty", tty: "ttys002")
        #expect(FocusRoute.route(for: session(host: host)) == .ghostty(tty: "/dev/ttys002"))
    }

    @Test func ghosttyWithoutTTYFallsBackToApp() {
        #expect(FocusRoute.route(for: session(host: HostInfo(termProgram: "ghostty"))) == .app)
    }

    @Test func claudeAppUsesDeepLink() {
        let host = HostInfo(entrypoint: "claude-desktop")
        let route = FocusRoute.route(for: session(host: host, appSessionId: "local_abc"))
        #expect(route == .claudeApp(appSessionId: "local_abc"))
        #expect(FocusRoute.claudeAppURL(appSessionId: "local_abc")?.absoluteString == "claude://code/continue?session=local_abc")
    }

    @Test func zedUsesProjectThenCurrentFolder() {
        var zed = session(host: HostInfo(termProgram: "zed", zedTerm: "true"), cwd: "/Users/u/code/my-app/sub")
        zed.projectDirectory = "/Users/u/code/my-app"
        #expect(FocusRoute.route(for: zed) == .zed(windowNames: ["my-app", "sub"]))
    }

    @Test func otherHostsActivateTheApp() {
        #expect(FocusRoute.route(for: session(host: HostInfo(termProgram: "Apple_Terminal", tty: "ttys001"))) == .app)
        #expect(FocusRoute.route(for: session(host: HostInfo())) == .app)
    }

    @Test func windowTitleMatchOrder() {
        let titles = ["my-app-old", "notes — README.md", "my-app — main.swift", "my-app"]
        #expect(FocusRoute.bestWindowIndex(titles: titles, names: ["my-app"]) == 3)
        #expect(FocusRoute.bestWindowIndex(titles: Array(titles.prefix(3)), names: ["my-app"]) == 2)
        #expect(FocusRoute.bestWindowIndex(titles: ["x", "old my-app copy"], names: ["my-app"]) == 1)
        #expect(FocusRoute.bestWindowIndex(titles: ["x"], names: ["my-app"]) == nil)
        #expect(FocusRoute.bestWindowIndex(titles: ["x"], names: []) == nil)
    }
}
