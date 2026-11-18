import SwiftUI

/// Expanded part of a card (PLAN §4).
struct TileDetailsView: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    DetailRow(label: "Model", value: modelText)
                    DetailRow(label: "Mode", value: session.permissionMode)
                    DetailRow(label: "Branch", value: session.gitBranch, monospaced: true)
                    DetailRow(label: "Folder", value: folderText, monospaced: true, truncation: .middle)
                    DetailRow(label: "Elapsed", value: elapsedText(now: timeline.date))
                    DetailRow(label: "Last event", value: lastEventText(now: timeline.date))
                    if session.subagentCount > 0 {
                        DetailRow(label: "Subagents", value: "\(session.subagentCount) running")
                    }
                    if let context = session.context {
                        GridRow {
                            DetailLabel(text: "Context")
                            ContextMeter(context: context)
                        }
                    }
                }
            }

            if let message = session.lastAssistantMessage, !message.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: "Last message")
                    Text(InlineMarkdown.text(message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !session.tasks.isEmpty {
                TaskListView(tasks: session.tasks, tint: session.state.tint)
            }
        }
    }

    private var modelText: String? {
        let parts = [session.model, session.effort.map { "effort \($0)" }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var folderText: String {
        (session.cwd as NSString).abbreviatingWithTildeInPath
    }

    private func elapsedText(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }

    private func lastEventText(now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(session.lastEventAt))
        if seconds < 5 { return "just now" }
        return session.lastEventAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String?
    var monospaced = false
    var truncation: Text.TruncationMode = .tail

    var body: some View {
        if let value, !value.isEmpty {
            GridRow {
                DetailLabel(text: label)
                Text(value)
                    .font(monospaced ? .caption.monospaced() : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(truncation)
            }
        }
    }
}

private struct DetailLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }
}

private struct ContextMeter: View {
    let context: ContextUsage

    var body: some View {
        HStack(spacing: 8) {
            LoungeProgressBar(fraction: context.fraction, tint: tint)
                .frame(width: 70)
            Text("\(compact(context.usedTokens)) / \(compact(context.limitTokens)) · \(Int((context.fraction * 100).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch context.fraction {
        case 0.95...: Color(nsColor: .systemRed)
        case 0.8...: Color(nsColor: .systemOrange)
        default: Color(nsColor: .systemGray)
        }
    }

    private func compact(_ tokens: Int) -> String {
        tokens.formatted(.number.notation(.compactName))
    }
}

private struct TaskListView: View {
    let tasks: [AgentTask]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "Tasks")
            ForEach(tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(for: task.status))
                        .font(.caption)
                        .foregroundStyle(color(for: task.status))
                    Text(task.status == .inProgress ? (task.activeForm ?? task.subject) : task.subject)
                        .font(.caption.weight(task.status == .inProgress ? .semibold : .regular))
                        .foregroundStyle(task.status == .completed ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func symbol(for status: AgentTask.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .pending: "circle"
        }
    }

    private func color(for status: AgentTask.Status) -> Color {
        switch status {
        case .completed: Color(nsColor: .systemGreen)
        case .inProgress: tint
        case .pending: .secondary
        }
    }
}
