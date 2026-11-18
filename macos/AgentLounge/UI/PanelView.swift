import SwiftUI

struct PanelActions {
    var toggleMute: () -> Void
    var togglePin: () -> Void
    var openSettings: () -> Void
    var close: () -> Void
}

/// Root view of the panel. Reports its natural height so the window can fit it.
struct PanelView: View {
    let store: SessionStore
    let preferences: Preferences
    let usage: UsageMonitor
    let layout: PanelLayout
    let actions: PanelActions
    let onHeightChange: (CGFloat) -> Void

    @State private var expandedIDs: Set<AgentSession.ID> = []
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let sessions = store.visibleSessions
        VStack(spacing: 0) {
            PanelHeader(
                count: sessions.count,
                topState: store.summary.topState,
                isMuted: preferences.isMuted,
                isPinned: preferences.isPinned,
                actions: actions
            )
            if preferences.showsUsage {
                UsageBar(usages: usage.usages, claudeEnabled: preferences.claudeUsageEnabled) {
                    preferences.claudeUsageEnabled = true
                }
            }
            if sessions.isEmpty {
                EmptyLoungeView(openSettings: actions.openSettings)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(sessions) { session in
                            TileView(
                                session: session,
                                isExpanded: expandedIDs.contains(session.id),
                                onToggleExpand: { toggleExpanded(session.id) },
                                onFocus: { store.focus(session.id) },
                                onHide: { store.hide(session.id) },
                                onDelete: { store.delete(session.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        listHeight = height
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(listHeight, layout.maxListHeight))
            }
        }
        .frame(width: PanelMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private func toggleExpanded(_ id: AgentSession.ID) {
        withAnimation(.snappy(duration: 0.25)) {
            if expandedIDs.contains(id) {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
            }
        }
    }
}

struct PanelHeader: View {
    let count: Int
    let topState: SessionState?
    let isMuted: Bool
    let isPinned: Bool
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(topState?.tint ?? Color.secondary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("Agent Lounge")
                .font(.headline)
            Text("\(count)")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            HeaderButton(
                systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: isMuted ? "Unmute sounds" : "Mute sounds",
                action: actions.toggleMute
            )
            HeaderButton(
                systemImage: isPinned ? "pin.fill" : "pin",
                help: isPinned ? "Unpin panel" : "Pin panel (float on top)",
                isActive: isPinned,
                action: actions.togglePin
            )
            HeaderButton(systemImage: "gearshape", help: "Settings", action: actions.openSettings)
            HeaderButton(systemImage: "xmark", help: "Close", action: actions.close)
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.headerHeight)
        .contentShape(.rect)
        // Drag the pinned panel by its header.
        .gesture(WindowDragGesture(), including: isPinned ? .all : .subviews)
    }
}

private struct HeaderButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(isHovering ? .primary : .secondary))
                .background(
                    Circle().fill(Color.primary.opacity(isHovering ? 0.10 : 0))
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
    }
}

private struct EmptyLoungeView: View {
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            AvatarView(state: .idle, color: ProjectPalette.colors[4])
                .frame(width: 44, height: 52)
            Text("No agents running")
                .font(.headline)
            Text("Sessions show up here when Claude Code or Codex starts. The agents need the Agent Lounge hooks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Hooks and Settings…", action: openSettings)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}
