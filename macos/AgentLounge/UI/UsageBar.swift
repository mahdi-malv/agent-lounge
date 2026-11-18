import SwiftUI

/// Plan usage under the panel header: one row per agent, two windows per row (5h and 7d).
struct UsageBar: View {
    let usages: [AgentUsage]
    let claudeEnabled: Bool
    var turnOnClaude: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 8) {
                if !claudeEnabled {
                    HStack(spacing: 8) {
                        AgentName(agent: .claude)
                        Button("Show Claude usage…", action: turnOnClaude)
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Reads the Claude Code sign-in from the Keychain. macOS asks for access once.")
                        Spacer(minLength: 0)
                    }
                }
                ForEach(usages, id: \.agent) { usage in
                    UsageRow(usage: usage, now: context.date)
                }
                if usages.isEmpty, claudeEnabled {
                    Text("No usage data yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }
}

private struct AgentName: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .leading)
    }
}

private struct UsageRow: View {
    let usage: AgentUsage
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            AgentName(agent: usage.agent)
            if let problem = usage.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                ForEach(usage.windows.prefix(2), id: \.label) { window in
                    UsageGauge(window: window, now: now)
                }
            }
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
    }

    private var helpText: String {
        var lines = usage.windows.map { window in
            var line = "\(window.label): \(Int(window.usedPercent.rounded())) % used"
            if let resetsAt = window.resetsAt {
                line += ", resets in \(UsageFormat.resetsIn(resetsAt, now: now)) (\(resetsAt.formatted(date: .omitted, time: .shortened)))"
            }
            return line
        }
        if let plan = usage.plan { lines.insert("\(usage.agent.label) \(plan.capitalized)", at: 0) }
        lines.append("Updated \(usage.updatedAt.formatted(.relative(presentation: .named)))")
        return lines.joined(separator: "\n")
    }
}

private struct UsageGauge: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(window.label)
                    .font(.caption2.weight(.semibold))
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.caption2)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if let resetsAt = window.resetsAt {
                    Text("↻ \(UsageFormat.resetsIn(resetsAt, now: now))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * min(1, max(0, window.usedPercent / 100)))
                    }
                }
        }
        .frame(maxWidth: .infinity)
    }

    private var tint: Color {
        switch window.usedPercent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }
}
