import CoreGraphics

/// Which screen(s) show the notch status.
nonisolated enum NotchPlacement: String, CaseIterable, Codable, Sendable {
    /// The screen under the mouse pointer.
    case mouse
    /// The screen with the focused window (`NSScreen.main`).
    case activeScreen
    /// The primary display (the one with the menu bar in Displays settings).
    case mainScreen
    case allScreens

    var label: String {
        switch self {
        case .mouse: "Screen with the pointer"
        case .activeScreen: "Screen with the active window"
        case .mainScreen: "Main screen"
        case .allScreens: "All screens"
        }
    }

    /// Indexes into `screens` of the screens that show the notch.
    /// - Parameters:
    ///   - screens: screen frames; index 0 is the primary display.
    ///   - mouse: pointer location in screen coordinates.
    ///   - active: index of the screen with the focused window, if known.
    func targets(screens: [CGRect], mouse: CGPoint, active: Int?) -> [Int] {
        guard !screens.isEmpty else { return [] }
        switch self {
        case .allScreens:
            return Array(screens.indices)
        case .mainScreen:
            return [0]
        case .activeScreen:
            return [active.flatMap { screens.indices.contains($0) ? $0 : nil } ?? 0]
        case .mouse:
            // Closed max edges, so the pointer at the top edge (y == maxY) still counts.
            let index = screens.firstIndex { frame in
                mouse.x >= frame.minX && mouse.x <= frame.maxX && mouse.y >= frame.minY && mouse.y <= frame.maxY
            }
            return [index ?? 0]
        }
    }
}

/// Top-of-screen facts the notch needs.
nonisolated struct NotchGeometry: Equatable, Sendable {
    /// Width of the camera housing. 0 on screens without a notch.
    var notchWidth: CGFloat
    /// Menu bar height (on a notched screen: the notch height).
    var barHeight: CGFloat

    var hasNotch: Bool { notchWidth > 0 }
}

/// Sizes of the notch pill, shared by the view (drawing) and the controller (hover hit test).
nonisolated enum NotchLayout {
    static let maxRows = 5
    static let rowHeight: CGFloat = 40
    static let bottomPadding: CGFloat = 8
    /// Status area on each side of a real notch.
    /// Room for two state counts.
    static let wingWidth: CGFloat = 52
    /// Pill width on a screen without a notch.
    static let plainWidth: CGFloat = 170
    static let expandedWidth: CGFloat = 400
    /// Concave flare at each top corner. Part of the pill width.
    static func topRadius(expanded: Bool) -> CGFloat { expanded ? 10 : 6 }
    static func bottomRadius(expanded: Bool) -> CGFloat { expanded ? 18 : 9 }
    /// Inset of the header content from each side of the pill.
    static func headerPadding(expanded: Bool) -> CGFloat { topRadius(expanded: expanded) + (expanded ? 10 : 6) }

    static func collapsedSize(_ geometry: NotchGeometry) -> CGSize {
        let flares = 2 * topRadius(expanded: false)
        let width = geometry.hasNotch ? geometry.notchWidth + 2 * wingWidth + flares : plainWidth
        return CGSize(width: width, height: geometry.barHeight)
    }

    static func expandedSize(_ geometry: NotchGeometry, rows: Int) -> CGSize {
        let rows = min(max(rows, 0), maxRows)
        let width = max(collapsedSize(geometry).width, expandedWidth)
        let body = rows > 0 ? CGFloat(rows) * rowHeight + bottomPadding : 0
        return CGSize(width: width, height: geometry.barHeight + body)
    }

    /// Rows of the expanded pill: most urgent first, then most recent.
    static func rows(_ sessions: [AgentSession]) -> [AgentSession] {
        let sorted = sessions.sorted { a, b in
            a.state.urgency != b.state.urgency ? a.state.urgency > b.state.urgency : a.lastEventAt > b.lastEventAt
        }
        return Array(sorted.prefix(maxRows))
    }

    /// Window size: room for the largest expanded pill.
    static func windowSize(_ geometry: NotchGeometry) -> CGSize {
        expandedSize(geometry, rows: maxRows)
    }

    /// Pill frame in screen coordinates (y up), centered on `centerX` and hanging from `top`.
    static func pillFrame(size: CGSize, centerX: CGFloat, top: CGFloat) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}
