import AppKit
import Observation
import SwiftUI

/// Borderless window above the menu bar. Mouse events pass through until the pill expands.
final class NotchWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        // Above the menu bar, like the panel of a menu-bar extra.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Keep the window over the menu bar; AppKit moves windows below it by default.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Shows the notch status on the screen(s) chosen in Settings, and expands it on hover.
final class NotchController {
    var onOpenPanel: (() -> Void)?

    private struct Entry {
        let window: NotchWindow
        let model: NotchModel
        var screen: NSScreen
    }

    private let store: SessionStore
    private let preferences: Preferences
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var observations: [Task<Void, Never>] = []
    private var mouseMonitors: [Any] = []
    private var screenTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var expandTask: Task<Void, Never>?

    /// Hover time before the pill expands, so a pass to a menu does not open it.
    private static let expandDelay: Duration = .milliseconds(150)

    init(store: SessionStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    func start() {
        let preferences = preferences
        let store = store
        observations = [
            Task { [weak self] in
                for await _ in Observations({ (preferences.notchEnabled, preferences.notchPlacement) }) {
                    self?.refresh()
                }
            },
            Task { [weak self] in
                for await _ in Observations({ store.summary.count }) {
                    self?.refresh()
                }
            },
        ]
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(rebuild: true) }
        }
    }

    func stop() {
        observations.forEach { $0.cancel() }
        observations = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        removeAll()
        stopTracking()
    }

    // MARK: - Screens

    private var isActive: Bool {
        preferences.notchEnabled && store.summary.count > 0
    }

    /// Show the pill on the target screens and remove it from the others.
    private func refresh(rebuild: Bool = false) {
        guard isActive else {
            removeAll()
            stopTracking()
            return
        }
        if rebuild { removeAll() }
        startTracking()

        let screens = NSScreen.screens
        let active = NSScreen.main.flatMap { main in screens.firstIndex { $0 == main } }
        let indexes = preferences.notchPlacement.targets(
            screens: screens.map(\.frame), mouse: NSEvent.mouseLocation, active: active
        )
        let targets = indexes.map { screens[$0] }
        let wanted = Set(targets.compactMap(\.displayID))

        for (id, entry) in entries where !wanted.contains(id) {
            entry.window.orderOut(nil)
            entries[id] = nil
        }
        for screen in targets {
            guard let id = screen.displayID else { continue }
            if var entry = entries[id] {
                entry.screen = screen
                entry.model.geometry = Self.geometry(of: screen)
                entries[id] = entry
                place(entry)
            } else {
                let entry = makeEntry(for: screen)
                entries[id] = entry
                place(entry)
                entry.window.orderFrontRegardless()
            }
        }
    }

    private func makeEntry(for screen: NSScreen) -> Entry {
        let model = NotchModel(geometry: Self.geometry(of: screen))
        let window = NotchWindow()
        let view = NotchView(store: store, model: model) { [weak self] in self?.onOpenPanel?() }
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.sizingOptions = []
        window.contentView = hosting
        return Entry(window: window, model: model, screen: screen)
    }

    private func place(_ entry: Entry) {
        let size = NotchLayout.windowSize(entry.model.geometry)
        let frame = NotchLayout.pillFrame(size: size, centerX: Self.centerX(of: entry.screen), top: entry.screen.frame.maxY)
        if entry.window.frame != frame {
            entry.window.setFrame(frame, display: true)
        }
    }

    private func removeAll() {
        expandTask?.cancel()
        for entry in entries.values { entry.window.orderOut(nil) }
        entries = [:]
    }

    static func geometry(of screen: NSScreen) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(notchWidth: max(0, width), barHeight: screen.safeAreaInsets.top)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(notchWidth: 0, barHeight: menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
    }

    /// Middle of the camera housing, or of the screen.
    private static func centerX(of screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return (left.maxX + right.minX) / 2
        }
        return screen.frame.midX
    }

    // MARK: - Hover and follow

    private func startTracking() {
        guard mouseMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.mouseMoved()
            return event
        }) {
            mouseMonitors.append(local)
        }
        // The focused screen has no change event; check it twice a second.
        screenTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.preferences.notchPlacement == .activeScreen else { return }
                self.refresh()
            }
        }
    }

    private func stopTracking() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        screenTimer?.invalidate()
        screenTimer = nil
    }

    private func mouseMoved() {
        let mouse = NSEvent.mouseLocation
        if preferences.notchPlacement == .mouse,
           let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           let id = screen.displayID, entries[id] == nil {
            refresh()
        }

        var wantsExpand = false
        for entry in entries.values {
            let model = entry.model
            let inside = isHovering(entry, expanded: model.isExpanded, mouse: mouse)
            if model.isExpanded, !inside {
                setExpanded(false, entry)
            } else if !model.isExpanded, inside {
                wantsExpand = true
            }
        }

        if wantsExpand {
            guard expandTask == nil else { return }
            expandTask = Task { [weak self] in
                try? await Task.sleep(for: Self.expandDelay)
                guard let self, !Task.isCancelled else { return }
                expandTask = nil
                expandHovered()
            }
        } else {
            expandTask?.cancel()
            expandTask = nil
        }
    }

    /// Expand the pill that is still under the pointer after the delay.
    private func expandHovered() {
        let mouse = NSEvent.mouseLocation
        for entry in entries.values where !entry.model.isExpanded && isHovering(entry, expanded: false, mouse: mouse) {
            setExpanded(true, entry)
        }
    }

    /// Pointer over the pill, with a 4 pt margin. The margin also covers the top edge,
    /// where the pointer stops at y == maxY.
    private func isHovering(_ entry: Entry, expanded: Bool, mouse: NSPoint) -> Bool {
        let geometry = entry.model.geometry
        let size = expanded
            ? NotchLayout.expandedSize(geometry, rows: NotchLayout.rows(store.visibleSessions).count)
            : NotchLayout.collapsedSize(geometry)
        let pill = NotchLayout.pillFrame(size: size, centerX: Self.centerX(of: entry.screen), top: entry.screen.frame.maxY)
        return pill.insetBy(dx: -4, dy: -4).contains(mouse)
    }

    private func setExpanded(_ expanded: Bool, _ entry: Entry) {
        entry.model.isExpanded = expanded
        entry.window.ignoresMouseEvents = !expanded
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
