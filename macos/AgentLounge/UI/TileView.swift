import SwiftUI

/// One card: compact row, plus details when expanded (PLAN §4).
struct TileView: View {
    let session: AgentSession
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onFocus: () -> Void
    let onHide: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                AvatarView(
                    state: session.avatarState,
                    look: PlanetRegistry.look(for: session),
                    moons: session.subagents.map(\.name),
                    phase: ProjectPalette.phase(for: session.id)
                )
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle)
                            .font(.system(.body, weight: .semibold))
                            .lineLimit(1)
                        HostBadge(text: session.hostBadgeText)
                            .layoutPriority(1)
                    }
                    Text(InlineMarkdown.text(session.subtitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressRow(session: session)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 1) {
                    TileIconButton(systemImage: "arrow.up.forward.square", help: "Focus session", action: onFocus)
                    TileIconButton(systemImage: "eye.slash", help: "Hide until the next event", action: onHide)
                    TileIconButton(systemImage: "xmark", help: "Remove card for this session", action: onDelete)
                }
            }

            if !session.subagents.isEmpty {
                SubagentList(subagents: session.subagents, isRunning: session.avatarState == .running)
                    .padding(.top, 8)
            }

            if isExpanded {
                TileDetailsView(session: session)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .background { TileBackground(state: session.state, isHovering: isHovering) }
        .contentShape(.rect(cornerRadius: PanelMetrics.tileCornerRadius))
        .onTapGesture(perform: onToggleExpand)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.displayTitle), \(session.state.label)")
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand", onToggleExpand)
    }
}

/// Running subagents, indented under their parent. Each has its moon, its name, and what it does now.
private struct SubagentList: View {
    let subagents: [Subagent]
    /// The parent runs: the moons turn.
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(subagents) { subagent in
                HStack(spacing: 8) {
                    MoonAvatarView(
                        name: subagent.name,
                        isAnimated: isRunning,
                        phase: ProjectPalette.phase(for: subagent.id)
                    )
                    .frame(width: 22, height: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(subagent.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(InlineMarkdown.text(subagent.activity ?? "Working…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Subagent \(subagent.name), \(subagent.activity ?? "working")")
            }
        }
        .padding(.leading, 14)
        // Line from the parent's planet down along its subagents.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.18))
                .frame(width: 2)
        }
        .padding(.leading, 25)
    }
}

private struct TileBackground: View {
    let state: SessionState
    let isHovering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.tileCornerRadius, style: .continuous)
        switch state {
        case .needsInput:
            shape.fill(state.tint.opacity(0.14))
                .overlay {
                    if reduceMotion {
                        shape.strokeBorder(state.tint.opacity(0.8), lineWidth: 1.5)
                    } else {
                        shape.strokeBorder(state.tint, lineWidth: 1.5)
                            .phaseAnimator([0.35, 0.9]) { border, opacity in
                                border.opacity(opacity)
                            } animation: { _ in
                                .easeInOut(duration: 0.9)
                            }
                    }
                }
        case .error:
            shape.fill(state.tint.opacity(0.10))
                .overlay { shape.strokeBorder(state.tint.opacity(0.5), lineWidth: 1) }
        case .running, .idle:
            shape.fill(Color.primary.opacity(isHovering ? 0.09 : 0.055))
        }
    }
}

struct ProgressRow: View {
    let session: AgentSession

    var body: some View {
        let tint = session.state.tint
        if let progress = session.progress {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    if let label = progress.label {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                LoungeProgressBar(fraction: progress.fraction, tint: tint)
            }
        } else if session.state == .running {
            LoungeProgressBar(fraction: nil, tint: tint)
                .padding(.top, 4)
        }
    }
}

struct HostBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

struct TileIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 18)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
    }
}

#Preview("Tiles") {
    let sessions = MockSessions.make()
    return ScrollView {
        VStack(spacing: 8) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                TileView(
                    session: session,
                    isExpanded: index == 0,
                    onToggleExpand: {},
                    onFocus: {},
                    onHide: {},
                    onDelete: {}
                )
            }
        }
        .padding(10)
    }
    .frame(width: PanelMetrics.width, height: 700)
}
