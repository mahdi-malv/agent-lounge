import Foundation
import Testing
@testable import AgentLounge

struct UsageTests {
    @Test func windowLabels() {
        #expect(UsageFormat.windowLabel(minutes: 300) == "5h")
        #expect(UsageFormat.windowLabel(minutes: 10080) == "7d")
        #expect(UsageFormat.windowLabel(minutes: 45) == "45m")
    }

    @Test func resetsIn() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UsageFormat.resetsIn(now.addingTimeInterval(30), now: now) == "now")
        #expect(UsageFormat.resetsIn(now.addingTimeInterval(45 * 60), now: now) == "45m")
        #expect(UsageFormat.resetsIn(now.addingTimeInterval(130 * 60), now: now) == "2h 10m")
        #expect(UsageFormat.resetsIn(now.addingTimeInterval(76 * 3600), now: now) == "3d 4h")
    }

    @Test func claudeUsageReply() throws {
        let json = """
        {"five_hour":{"utilization":12.0,"resets_at":"2026-11-18T14:00:00.123+00:00"},
         "seven_day":{"utilization":35.5,"resets_at":"2026-11-21T09:00:00+00:00"},
         "seven_day_opus":{"utilization":0.0,"resets_at":null},
         "seven_day_sonnet":{"utilization":20.0,"resets_at":"2026-11-21T09:00:00+00:00"},
         "extra_usage":null}
        """
        let windows = try #require(ClaudeUsageParser.parse(Data(json.utf8)))
        #expect(windows.map(\.label) == ["5h", "7d", "7d Sonnet"])
        #expect(windows[0].usedPercent == 12)
        #expect(windows[0].remainingPercent == 88)
        #expect(windows[0].resetsAt == ClaudeUsageParser.parseDate("2026-11-18T14:00:00.123Z"))
        #expect(ClaudeUsageParser.parse(Data("[]".utf8)) == nil)
    }

    @Test func codexRateLimitsTakeTheLastLine() throws {
        let now = Date(timeIntervalSince1970: 1_794_970_000)
        let lines = [
            #"{"timestamp":"2026-11-18T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1794981203}}}}"#,
            #"{"timestamp":"2026-11-18T01:10:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":2.0,"window_minutes":300,"resets_at":1794981203},"secondary":{"used_percent":11.0,"window_minutes":10080,"resets_at":1795178679},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-11-18T01:11:00.000Z","type":"response_item","payload":{"type":"message"}}"#,
        ]
        let result = try #require(CodexUsageParser.lastRateLimits(in: Data(lines.joined(separator: "\n").utf8), now: now))
        #expect(result.windows.map(\.label) == ["5h", "7d"])
        #expect(result.windows.map(\.usedPercent) == [2, 11])
        #expect(result.windows[1].resetsAt == Date(timeIntervalSince1970: 1_795_178_679))
        #expect(result.plan == "plus")
    }

    @Test func codexWindowPastItsResetIsEmpty() throws {
        let line = #"{"timestamp":"2026-11-18T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":80.0,"window_minutes":300,"resets_in_seconds":60}}}}"#
        let later = try #require(ClaudeUsageParser.parseDate("2026-11-18T02:00:00Z"))
        let result = try #require(CodexUsageParser.lastRateLimits(in: Data(line.utf8), now: later))
        #expect(result.windows[0].usedPercent == 0)
        #expect(result.windows[0].resetsAt == nil)
    }

    @Test func claudeCredentials() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1794981203000,"subscriptionType":"max"}}"#
        let credentials = try #require(UsageMonitor.parseClaudeCredentials(Data(json.utf8)))
        #expect(credentials.accessToken == "tok")
        #expect(credentials.plan == "max")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_794_981_203))
        #expect(UsageMonitor.parseClaudeCredentials(Data("{}".utf8)) == nil)
    }

    @Test func snapshotCarriesUsage() throws {
        let usage = AgentUsage(agent: .codex, plan: nil, windows: [UsageWindow(label: "5h", usedPercent: 2, resetsAt: nil)],
                               updatedAt: Date(timeIntervalSince1970: 0))
        let message = ServerMessage(type: .snapshot, sessions: [], usage: [usage])
        let json = try #require(String(data: RemoteCoding.encoder.encode(message), encoding: .utf8))
        #expect(json.contains(#""usage":[{"agent":"codex","updatedAt":"1970-01-01T00:00:00Z","windows":[{"label":"5h","usedPercent":2}]}]"#))
    }
}
