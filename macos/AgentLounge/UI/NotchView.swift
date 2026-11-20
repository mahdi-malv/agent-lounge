import SwiftUI

/// State of one notch window, set by `NotchController`.
@Observable
final class NotchModel {
    var geometry: NotchGeometry
    var isExpanded = false

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

/// Black pill at the top center of a screen. Collapsed: top state and card count beside the
/// notch. Expanded (hover): the most urgent sessions; a click on a row shows its window.
struct NotchView: View {
    let store: SessionStore
    let model: NotchModel
    var onOpenPanel: () -> Void

    var body: some View {
        let geometry = model.geometry
        let expanded = model.isExpanded
        let _ = PlanetRegistry.sync(store.sessions)
        let rows = expanded ? NotchLayout.rows(store.visibleSessions) : []
        let size = expanded
            ? NotchLayout.expandedSize(geometry, rows: rows.count)
            : NotchLayout.collapsedSize(geometry)
        let shape = NotchShape(
            topRadius: NotchLayout.topRadius(expanded: expanded),
            bottomRadius: NotchLayout.bottomRadius(expanded: expanded)
        )

        VStack(spacing: 0) {
            NotchHeader(summary: store.summary, geometry: geometry, width: size.width, expanded: expanded)
                .frame(height: geometry.barHeight)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenPanel)
                .help("Show Agent Lounge")
            if expanded {
                VStack(spacing: 0) {
                    ForEach(rows) { session in
                        NotchRow(session: session) { store.focus(session.id) }
                    }
                }
                .padding(.horizontal, NotchLayout.topRadius(expanded: true) + 4)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 8, y: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.28, bounce: 0.15), value: expanded)
        .animation(.easeInOut(duration: 0.2), value: rows.map(\.id))
        .environment(\.colorScheme, .dark)
    }
}

private struct NotchHeader: View {
    let summary: StoreSummary
    let geometry: NotchGeometry
    /// Pill width.
    let width: CGFloat
    let expanded: Bool

    /// Left: most urgent state with its count (and its name when there is room).
    /// Right: the other states with their counts. Least urgent counts drop when there is no room.
    var body: some View {
        let padding = NotchLayout.headerPadding(expanded: expanded)
        let showsLabel = !geometry.hasNotch || expanded
        let top = summary.counts.first
        let rest = Array(summary.counts.dropFirst())
        Group {
            if geometry.hasNotch {
                // One side of the camera housing each; nothing may go under it.
                let side = max((width - geometry.notchWidth) / 2 - padding, 0)
                HStack(spacing: 0) {
                    TopCount(item: top, showsLabel: showsLabel)
                        .frame(width: side, alignment: .leading)
                    Spacer(minLength: 0)
                    OtherCounts(items: rest)
                        .frame(width: side, alignment: .trailing)
                }
            } else {
                HStack(spacing: 0) {
                    TopCount(item: top, showsLabel: showsLabel)
                        .fixedSize()
                    OtherCounts(items: rest)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.leading, 6)
                }
            }
        }
        .padding(.horizontal, padding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent Lounge, \(summary.count) agents: \(summary.spokenCounts)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Most urgent state: dot, count and, when it fits, the state name.
private struct TopCount: View {
    let item: StateCount?
    let showsLabel: Bool

    var body: some View {
        if let item {
            ViewThatFits(in: .horizontal) {
                if showsLabel {
                    HStack(spacing: 5) {
                        StateCountChip(item: item)
                        Text(item.state.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(nsColor: item.state.statusColor))
                            .lineLimit(1)
                    }
                }
                StateCountChip(item: item)
            }
        }
    }
}

/// Other states, most urgent first. Shows as many as fit (at most 3 states remain).
private struct OtherCounts: View {
    let items: [StateCount]

    var body: some View {
        if !items.isEmpty {
            ViewThatFits(in: .horizontal) {
                chips(items)
                chips(Array(items.prefix(2)))
                chips(Array(items.prefix(1)))
            }
        }
    }

    private func chips(_ items: [StateCount]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.state) { StateCountChip(item: $0) }
        }
    }
}

private struct StateCountChip: View {
    let item: StateCount

    var body: some View {
        HStack(spacing: 3) {
            StateDot(state: item.state)
            Text("\(item.count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

private struct StateDot: View {
    let state: SessionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let animated = !reduceMotion && (state == .running || state == .needsInput)
        Circle()
            .fill(Color(nsColor: state.statusColor))
            .frame(width: 8, height: 8)
            .opacity(animated && pulse ? 0.35 : 1)
            .animation(animated ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

private struct NotchRow: View {
    let session: AgentSession
    var onFocus: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: 10) {
                AvatarView(
                    state: session.avatarState,
                    look: PlanetRegistry.look(for: session),
                    moons: session.subagents.map(\.name),
                    phase: ProjectPalette.phase(for: session.id)
                )
                .frame(height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(session.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(session.state.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(session.state.tint)
            }
            .padding(.horizontal, 8)
            .frame(height: NotchLayout.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show this session's window")
    }
}

/// Notch outline: concave flares at the top corners, rounded bottom corners.
nonisolated struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = topRadius
        let bottom = min(bottomRadius, rect.height / 2, (rect.width - 2 * top) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
