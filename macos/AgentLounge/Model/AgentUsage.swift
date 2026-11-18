import Foundation

/// One plan limit window, e.g. Claude "5h" at 12 % that resets at 14:00.
nonisolated struct UsageWindow: Codable, Hashable, Sendable {
    /// Short name: "5h", "7d", "7d Opus".
    var label: String
    /// 0…100.
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

/// Plan usage of one agent (top bar of the panel and the phone).
nonisolated struct AgentUsage: Codable, Hashable, Sendable {
    var agent: AgentKind
    /// Plan name if known ("max", "pro", "plus").
    var plan: String?
    var windows: [UsageWindow]
    /// When the numbers were read (Codex: time of the last rollout event with limits).
    var updatedAt: Date
    /// Short reason when there are no numbers ("Not signed in", "Sign-in expired").
    var problem: String?
}

nonisolated enum UsageFormat {
    /// 300 → "5h", 10080 → "7d", 45 → "45m".
    static func windowLabel(minutes: Int) -> String {
        if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// Time to reset: "2h 10m", "3d 4h", "45m", "now".
    static func resetsIn(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 59 else { return "now" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return hours % 24 > 0 ? "\(days)d \(hours % 24)h" : "\(days)d" }
        if hours > 0 { return minutes % 60 > 0 ? "\(hours)h \(minutes % 60)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}

/// Parses `GET https://api.anthropic.com/api/oauth/usage` (Claude Code's `/usage` data).
/// `{"five_hour":{"utilization":12.0,"resets_at":"2026-11-18T14:00:00+00:00"},"seven_day":{…},
///   "seven_day_opus":{…}|null,"seven_day_sonnet":{…}|null, …}`. `utilization` is a percent.
nonisolated enum ClaudeUsageParser {
    static let windows: [(key: String, label: String)] = [
        ("five_hour", "5h"),
        ("seven_day", "7d"),
        ("seven_day_opus", "7d Opus"),
        ("seven_day_sonnet", "7d Sonnet"),
    ]

    static func parse(_ data: Data) -> [UsageWindow]? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = root else { return nil }
        let found = windows.compactMap { key, label -> UsageWindow? in
            guard let window = root[key], case .number(let used)? = window["utilization"] else { return nil }
            return UsageWindow(label: label, usedPercent: used, resetsAt: window["resets_at"]?.stringValue.flatMap(parseDate))
        }
        // Model windows only when they are in use: they repeat the 7d bar otherwise.
        return found.filter { $0.label == "5h" || $0.label == "7d" || $0.usedPercent > 0 }
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Finds the newest `rate_limits` in a Codex rollout (`event_msg` `token_count`):
/// `{"primary":{"used_percent":2.0,"window_minutes":300,"resets_at":1794981203},"secondary":{…},…}`.
/// Old Codex builds wrote `resets_in_seconds` (relative to the line `timestamp`).
nonisolated enum CodexUsageParser {
    struct Result: Equatable {
        var windows: [UsageWindow]
        var readAt: Date
        var plan: String?
    }

    static func lastRateLimits(in data: Data, now: Date = .now) -> Result? {
        let decoder = JSONDecoder()
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            guard let entry = try? decoder.decode(JSONValue.self, from: line),
                  let limits = entry["payload"]?["rate_limits"], case .object = limits else { continue }
            let readAt = entry["timestamp"]?.stringValue.flatMap(ClaudeUsageParser.parseDate) ?? .now
            let windows = ["primary", "secondary"].compactMap { key in window(limits[key], readAt: readAt, now: now) }
            guard !windows.isEmpty else { continue }
            return Result(windows: windows, readAt: readAt, plan: limits["plan_type"]?.stringValue)
        }
        return nil
    }

    private static func window(_ value: JSONValue?, readAt: Date, now: Date) -> UsageWindow? {
        guard let value, case .number(let used)? = value["used_percent"] else { return nil }
        let minutes = value["window_minutes"]?.intValue
        var resetsAt: Date?
        if case .number(let epoch)? = value["resets_at"] {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if case .number(let seconds)? = value["resets_in_seconds"] {
            resetsAt = readAt.addingTimeInterval(seconds)
        }
        // A window that has reset since the event is back at 0 %.
        let isOver = resetsAt.map { $0 < now } ?? false
        return UsageWindow(
            label: minutes.map(UsageFormat.windowLabel) ?? "limit",
            usedPercent: isOver ? 0 : used,
            resetsAt: isOver ? nil : resetsAt
        )
    }
}
