import CoreGraphics
import Foundation
import Testing
@testable import AgentLounge

struct NotchLayoutTests {
    /// Primary 1512 × 982 at the origin, second screen 1920 × 1080 to its right.
    private let screens = [
        CGRect(x: 0, y: 0, width: 1512, height: 982),
        CGRect(x: 1512, y: 0, width: 1920, height: 1080),
    ]

    @Test func placementPicksScreens() {
        let onSecond = CGPoint(x: 2000, y: 500)
        #expect(NotchPlacement.mouse.targets(screens: screens, mouse: onSecond, active: 0) == [1])
        #expect(NotchPlacement.mouse.targets(screens: screens, mouse: CGPoint(x: 2000, y: 1080), active: 0) == [1])
        #expect(NotchPlacement.mouse.targets(screens: screens, mouse: CGPoint(x: -50, y: -50), active: 1) == [0])
        #expect(NotchPlacement.activeScreen.targets(screens: screens, mouse: .zero, active: 1) == [1])
        #expect(NotchPlacement.activeScreen.targets(screens: screens, mouse: .zero, active: nil) == [0])
        #expect(NotchPlacement.activeScreen.targets(screens: screens, mouse: .zero, active: 7) == [0])
        #expect(NotchPlacement.mainScreen.targets(screens: screens, mouse: onSecond, active: 1) == [0])
        #expect(NotchPlacement.allScreens.targets(screens: screens, mouse: .zero, active: nil) == [0, 1])
        #expect(NotchPlacement.mouse.targets(screens: [], mouse: .zero, active: nil).isEmpty)
    }

    @Test func sizesWrapTheNotch() {
        let notched = NotchGeometry(notchWidth: 200, barHeight: 32)
        let collapsed = NotchLayout.collapsedSize(notched)
        #expect(collapsed.height == 32)
        #expect(collapsed.width > 200 + 2 * NotchLayout.wingWidth)

        let plain = NotchGeometry(notchWidth: 0, barHeight: 24)
        #expect(!plain.hasNotch)
        #expect(NotchLayout.collapsedSize(plain) == CGSize(width: NotchLayout.plainWidth, height: 24))

        #expect(NotchLayout.expandedSize(plain, rows: 0).height == 24)
        let two = NotchLayout.expandedSize(plain, rows: 2)
        #expect(two.height == 24 + 2 * NotchLayout.rowHeight + NotchLayout.bottomPadding)
        #expect(NotchLayout.expandedSize(plain, rows: 99) == NotchLayout.windowSize(plain))
    }

    @Test func pillHangsFromTheTopCenter() {
        let frame = NotchLayout.pillFrame(size: CGSize(width: 100, height: 30), centerX: 500, top: 982)
        #expect(frame == CGRect(x: 450, y: 952, width: 100, height: 30))
    }

    @Test func rowsAreMostUrgentFirst() {
        let now = Date.now
        func session(_ id: String, _ state: SessionState, _ age: TimeInterval) -> AgentSession {
            AgentSession(id: id, agent: .claude, host: .unknown, state: state, cwd: "/tmp/\(id)",
                         startedAt: now, lastEventAt: now.addingTimeInterval(-age))
        }
        let rows = NotchLayout.rows([
            session("a", .idle, 0),
            session("b", .running, 10),
            session("c", .needsInput, 50),
            session("d", .running, 5),
            session("e", .error, 0),
            session("f", .idle, 1),
        ])
        #expect(rows.map(\.id) == ["c", "e", "d", "b", "a"])
    }
}
